# Rust Backend

Rust crate lives in `rust/`. Compiled into shared lib consumed by both Dart (via flutter_rust_bridge) and Kotlin (via UniFFI). Both FFI layers active simultaneously from same compiled binary.

## Crate Structure

| File | Size | Purpose |
|------|------|---------|
| `rust/src/lib.rs` | ~54 lines | Runtime bootstrap: declares `RUNTIME`, initializes logger, declares modules |
| `rust/src/api/api.rs` | ~2800 lines | Main orchestration: `SharedPushState`, `recv_wait`, `send`, `do_login`, sync API, CloudKit API |
| `rust/src/api/mirrors.rs` | ~1700 lines | FFI mirror types (`Dart*` structs); included via `include!` macro in FRB-generated code |
| `rust/src/api/mod.rs` | small | Module declaration |
| `rust/src/native.rs` | ~370 lines | UniFFI/Kotlin bindings: `NativePushState`, `MsgReceiver` trait, `QUEUED_MESSAGES`, `start_loop` |
| `rust/src/keystore.rs` | ~585 lines | `NativeKeystore` UniFFI trait + `NativeKeystoreHolder` adapter; key wrapping for Android Keystore import |
| `rust/src/frb_generated.rs` | generated | flutter_rust_bridge glue — do not edit manually |

## Tokio Runtime

```rust
// rust/src/lib.rs
pub static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("tokio-rustpush")
        .enable_all()
        .build().unwrap()
});
```

- Single-threaded Tokio runtime (`worker_threads(1)`)
- All async Rust work runs on one OS thread named `tokio-rustpush`
- Initialized lazily on first access via `LazyLock`
- FRB exposes custom async runtime (`MyAsyncRuntime`) that spawns into `RUNTIME`

## `SharedPushState` Struct

```rust
// rust/src/api/api.rs L521-541
#[frb(non_opaque)]
#[derive(Clone)]
pub struct SharedPushState {
    pub os_config: JoinedOSConfig,
    pub cancel_poll: mpsc::Sender<()>,
    pub conf_dir: String,
    pub local_broadcast: Arc<mpsc::Sender<PushMessage>>,

    pub anisette: ArcAnisetteClient<DefaultAnisetteProvider>,
    pub conn: APSConnection,           // Apple Push Service connection
    pub icloud_services: Option<SharedICloudServices>,

    pub client: Arc<IMClient>,         // iMessage client
    pub ft_client: Arc<FTClient>,      // FaceTime client
    pub idms_client: Arc<IdmsAuthListener>,

    pub active_circle_sessions: Arc<Mutex<Vec<ActiveCircleSession>>>,
    pub client_session: Arc<Mutex<Option<CircleClientSession<...>>>>,
}
```

- `Clone` derived — cheap; inner data is `Arc`-wrapped
- Dart receives as opaque handle; on desktop via `dup_daemon_desk()`, on Android via `DaemonData` pointer
- `icloud_services` is `Option` — absent if Apple ID login not completed

## `SharedICloudServices` Composition

```rust
// rust/src/api/api.rs L549-561
pub struct SharedICloudServices {
    pub account: Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>,
    pub token_provider: Arc<TokenProvider<DefaultAnisetteProvider>>,
    pub cloudkit_client: Option<Arc<CloudKitClient<...>>>,
    pub keychain: Option<Arc<KeychainClient<...>>>,
    pub passwords: Option<Arc<PasswordManager<...>>>,
    pub profiles_client: Arc<ProfilesClient<...>>,
    pub fmfd: Option<Arc<FindMyClient<...>>>,
    pub sharedstreams: Option<SyncManager<...>>,
    pub cloud_messages_client: Option<Arc<CloudMessagesClient<...>>>,
    pub statuskit_client: Arc<StatusKitClient<...>>,
}
```

Optional fields absent if capability unavailable (e.g., `keychain` requires hardware keystore).

## `recv_wait()` Select Loop

`recv_wait()` (`api.rs` L1738) — central message dispatch. Runs inside async `select!`; dispatches exactly one incoming APS packet sequentially through handler chain:

```
inq_queue.recv() (new APS packet) →
    1. fmfd.handle()        — Find My Friends beacon
    2. photostream.handle() — Shared Streams photo changes
    3. statuskit.handle()   — Focus/status updates → PushMessage::StatusUpdate
    4. passwords.handle()   — iCloud Keychain sync
    5. idms_client.handle() — IDMS auth (2FA circle, sign-in requests)
    6. ft_client.handle()   — FaceTime signaling → PushMessage::FaceTime
    7. client.handle()      — iMessage → PushMessage::IMessage

reg_state.changed()         → PushMessage::RegistrationState
local_messages.recv()       → pass-through (e.g. SendConfirm)
cancel_poll_recv.recv()     → PollResult::Stop
```

Each call returns at most one `PollResult::Cont(Some(PushMessage))`. Caller loops.

## `QUEUED_MESSAGES` — Cross-FFI Message Queue

```rust
// rust/src/native.rs
pub static QUEUED_MESSAGES: LazyLock<Mutex<(u64, HashMap<u64, PushMessage>)>> =
    LazyLock::new(|| Mutex::new((0, HashMap::new())));
```

- `(counter, map)`: `counter` monotonically increasing key (wrapping u64); `map` stores `PushMessage` keyed by counter
- On message arrival: inserted, `receieved_msg(key, 0)` called on `MsgReceiver` callback
- **Retry task** spawned per message: sleeps 30s, re-emits `receieved_msg(key, retry)` up to 5 times if key still present
- **Retry task never cancelled when Dart ACKs** — Dart must call `api.completeMsg(key)` to remove from map; retry task finds it absent and stops

## `SharedPushState::restore()` — Startup Sequence

Called on first run on desktop (no existing state pointer). On Android called by `initNative()` when no handle passed.

Sequential startup steps (from `api.rs` L564–649):

1. `init_keystore(SoftwareKeystore {...})` — desktop only; uses hardcoded 32-byte AES key (see Keystore section)
2. `migrate(path)` — on-disk migration with `catch_unwind`
3. `read_hardware(path)` — load hardware state (device identity, push credentials)
4. `restore_users(path)` — load stored Apple ID user session
5. `setup_push(config, identity, push, path)` — establish APS connection
6. `make_imclient(path, conn, users, identity)` — create IMClient
7. `make_anisette(path, config, conn)` — create anisette (GSA auth) client
8. `restore_account(path, anisette, config, conn)` — restore Apple ID account session
9. `make_token_provider(account, config)` — create iCloud token provider
10. `make_cloudkit(path, anisette, config, token_provider)` — create CloudKit client
11. `make_keychain(path, cloudkit, anisette, config, token_provider)` — create KeychainClient
12. `make_passwords(path, keychain, cloudkit, client, conn)` — create PasswordManager
13. `make_profiles(cloudkit)` — create ProfilesClient
14. `make_findmy(...)` — create FindMyClient (requires keychain)
15. `make_shared_streams(path, conn, anisette, config
, token_provider)` — create SyncManager
16. `make_cloud_messages_client(cloudkit, keychain)` — create CloudMessagesClient
17. `make_statuskit(path, token_provider, conn, config, client)` — create StatusKitClient
18. `make_facetime(path, conn, client)` — create FTClient
19. `make_idms(conn)` — create IdmsAuthListener

Returns `Option<(SharedPushState, APSWatcher)>` — `None` on any fatal failure.

## `send_daemon()` — Cross-Process State Transfer (Desktop)

Hands off `SharedPushState` from Rust init context to receiving context, encoded as raw pointer decimal string:

```rust
// api.rs L501-512
pub fn send_daemon(state: SharedPushState, watcher: APSWatcher) -> (String, SharedPushState) {
    let data = DaemonData { watcher, state: state.clone() };
    let num = Box::into_raw(Box::new(data)) as u64;
    (num.to_string(), state)
}
```

Consumer calls `init_native(dir, Some(handle_string), handler)` in `native.rs`:

```rust
let parsed: u64 = handle.parse().expect("bad handle??");
let daemondata: DaemonData = *unsafe { Box::from_raw(parsed as *mut DaemonData) };
```

Transfers heap ownership without copying underlying data. Pointer valid only within same process. On Android, `APNService.getState()` returns `Arc<SharedPushState>` pointer instead.

## Keystore Selection

```rust
// api.rs L569-576 — desktop path
#[cfg(not(target_os = "android"))]
init_keystore(SoftwareKeystore {
    state: plist::from_file(&keystore).unwrap_or_default(),
    update_state: Box::new(move |state| { plist::to_file_xml(&keystore, state).unwrap(); }),
    encryptor: SoftwareEncryptor(*b"desktopisinsecureyoushouldn'tber"),
});
```

| Platform | Keystore Type | Notes |
|----------|---------------|-------|
| Desktop (macOS/Linux/Windows) | `SoftwareKeystore` | Hardcoded 32-byte AES key `*b"desktopisinsecureyoushouldn'tber"`; state serialized to `keystore.plist` |
| Android | `AndroidNativeKeystore` | Implements `NativeKeystore` UniFFI trait; wraps Android Keystore JNI; set up via `setupKeystore()` UniFFI call |

`SoftwareKeystore` key intentionally insecure (comment in source: `"desktopisinsecureyoushouldn'tber"`). Desktop identity material not hardware-protected.

## Two Simultaneous FFI Layers

Compiled Rust lib exposes two independent FFI surfaces, both active at runtime:

| FFI Layer | Macro | Consumer | Generated Output |
|-----------|-------|----------|-----------------|
| flutter_rust_bridge (FRB) | `#[frb(...)]` annotations | Dart | `lib/src/rust/` — Dart bindings |
| UniFFI | `#[uniffi::export]` / `uniffi::setup_scaffolding!()` | Kotlin | `android/` — Kotlin bindings (`uniffi.rust_lib_bluebubbles.*`) |

FRB calls go through `FLUTTER_RUST_BRIDGE_HANDLER` using `MyAsyncRuntime` to spawn on `RUNTIME`. UniFFI calls go through UniFFI scaffolding; may be called from any Kotlin thread.

## `NativePushState.start_loop()` — Android Message Loop

```rust
// native.rs L160-221
pub fn start_loop(self: Arc<NativePushState>, handler: Arc<dyn MsgReceiver>) {
    RUNTIME.spawn(async move {
        let mut watcher = self.watcher.lock().await;
        loop {
            match AssertUnwindSafe(recv_wait(&mut watcher, &self.state))
                .catch_unwind().await
            {
                Ok(PollResult::Cont(Some(msg))) => {
                    if let PushMessage::TwoFaAuthEvent(event) = &msg {
                        handler.twofa_event(*event);
                        continue; // 2FA events bypass the queue
                    }
                    // insert into QUEUED_MESSAGES
                    let mut locked = QUEUED_MESSAGES.lock().await;
                    let key = locked.0;
                    locked.1.insert(key, msg);
                    locked.0 = locked.0.wrapping_add(1);
                    drop(locked);
                    // spawn retry task (30s × 5 retries)
                    let handler_ref = handler.clone();
                    tokio::spawn(async move {
                        let mut retry = 0;
                        tokio::time::sleep(Duration::from_secs(30)).await;
                        while QUEUED_MESSAGES.lock().await.1.contains_key(&key) {
                            retry += 1;
                            if retry > 5 {
                                QUEUED_MESSAGES.lock().await.1.remove(&key);
                                break;
                            }
                            handler_ref.receieved_msg(key, retry);
                            tokio::time::sleep(Duration::from_secs(30)).await;
                        }
                    });
                    handler.receieved_msg(key, 0);
                },
                Ok(PollResult::Cont(None)) => continue,
                Ok(PollResult::Stop) => break,
                Err(payload) => { error!("Failed {:?}", panic); }
            }
        }
        handler.finish();
    });
}
```

Key behaviors:
- `catch_unwind` wraps each `recv_wait` call — panic in Rust handler does **not** crash process
- `TwoFaAuthEvent` dispatched directly to `twofa_event()` — **skips** queue
- Each message spawns own retry task; tasks not cancelled when Dart ACKs — Dart removal from `QUEUED_MESSAGES` is ACK signal

## `get_auth_code()` — Deadlock Risk

```rust
// native.rs L348-361
pub fn get_auth_code(&self, txnid: String) -> u32 {
    // ...
    RUNTIME.block_on(async move {
        match approve_circle(&data_ref, &state_ref, txnid).await { ... }
    })
}
```

`RUNTIME.block_on()` blocks calling thread until future completes. If `get_auth_code()` called **from within a Tokio context** (task already running on `RUNTIME`), this **deadlocks** — single worker thread already occupied. Must only be called from non-Tokio thread (e.g., Kotlin coroutine on `Dispatchers.IO`).
