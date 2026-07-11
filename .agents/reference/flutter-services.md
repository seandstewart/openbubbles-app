# Flutter Service Layer

## `RustPushService`

**File:** `lib/services/rustpush/rustpush_service.dart`  
**Type:** `GetxService` (~5000 lines)  
**Global accessor:** `pushService` (top-level variable)

Central iMessage backend. Owns Rust `SharedPushState` handle on desktop; receives it from `APNService` on Android. Implements most iMessage business logic on Dart side.

### `initFuture`

Lazy `Future` capturing full async init sequence. Other services `await pushService.initFuture` before calling Rust APIs.

- **Android path:** reads native handle via `MethodChannel` (`get-native-handle`), calls `api.initNative()` which consumes pointer from `APNService` and calls `handler.native_ready(state)` back to Dart
- **Desktop path:** calls `api.SharedPushState.restore(path)` directly, then starts `doPoll()`

### Periodic Timers

Two `Timer.periodic` timers started at init (approx. daily):
- **Password sync timer:** calls `api.syncPasswords(...)`
- **CloudKit sync timer:** triggers `doCloudKitSync()` if cloud syncing enabled

### `doPoll()`

```dart
Future<void> doPoll() async {
  while (true) {
    var msg = await api.recvWait(watcher: state!.watcher, state: state!);
    await handleMsgInner(msg);
  }
}
```

- Runs on **main Dart isolate** on desktop only (Android uses native service loop)
- No error backoff or retry delay — correctness relies on `recv_wait()` blocking until message arrives or error occurs in Rust
- If `recv_wait()` throws, `while(true)` loop terminates; app stops receiving messages until restarted

### `handleMsgInner()`

~250-line dispatch on `PushMessage` subtypes:

| PushMessage Variant | Action |
|--------------------|--------|
| `IMessage(msg)` | Calls `handleIMessage()` → `reflectMessageDyn()` → `inq.queue()` |
| `FaceTime(msg)` | Routes FaceTime events (ring, join, leave, decline) |
| `RegistrationState(state)` | Updates registration status; shows notification if deregistered |
| `SMS(msg)` | Handles forwarded SMS messages |
| `TwoFaAuthEvent(success)` | Updates 2FA UI |
| `Idms(msg)` | Handles IDMS sign-in requests |
| `BeaconShared(...)` | Processes Find My beacon shares |
| `NewPhotostream(...)` | Handles shared streams photo updates |
| `CircleFinishEvent(...)` | Handles circle PAKE completion |

### `reflectMessageDyn()`

~300-line method converting `api.MessageInst` variants into BB `Message` model. Called on:
1. **Inbound messages** — after `recv_wait()` returns an IMessage
2. **Outbound messages** — immediately after `api.send()` to produce locally-reflected message
3. **CloudKit sync** — when syncing remote messages down from iCloud

Handles all message types: normal, reactions, edits, unsend, rename, participant change, icon change, profile updates, more. Calls `indexedPartsToAttributedBodyDyn()` to convert Rust `MessagePart` variants into BB `AttributedBody` + `Attachment` objects.

### `doCloudKitSyncPrivate()` — 5-Phase CloudKit Sync

Called from `backgroundSyncIsolate()` on Android, or directly on desktop.

**Phase 1 — Flush pending deletions:**
- Sends queued message/chat/attachment deletion IDs to CloudKit; clears queued lists

**Phase 2 — Loop sync chats:**
- Calls `api.syncChats()` in `while(currentState != 3)` loop using continuation tokens
- Applies each incoming `DartCloudChat` via `Chat.applyFromCloud()`
- Downloads group profile photos

**Phase 3 — Loop sync attachments:**
- Calls `api.syncAttachments()` in loop
- Applies cutoff time to skip items older than configured history window
- Skips items already existing locally

**Phase 4 — Loop sync messages:**
- Calls `api.syncMessages()` in loop
- Applies cutoff time; skips existing messages; calls `message.applyFromCloud()`

**Phase 5 — Upload unsynced local data:**
- Queries unsynced chats (`ckSyncState == false`); uploads in batches
- Queries unsynced messages in batches of **3000** via `..limit = 3000`; calls `uploadMessages()` repeatedly

### `eraseCloudKitSync()`

Resets all CloudKit sync state. **Danger:** loads `Database.messages.getAll()`, `Database.chats.getAll()`, and `Database.attachments.getAll()` — three full table scans into memory simultaneously. Can cause OOM on Android with large databases.

### `backgroundSyncIsolate()`

```dart
@pragma('vm:entry-point')
Future<void> backgroundSyncIsolate() async { ... }
```

- `@pragma('vm:entry-point')` required so Dart VM doesn't tree-shake function in release mode
- Runs in `FlutterIsolate` (Android only) — separate Flutter engine instance
- Registers named port `"bg_sync"` via `IsolateNameServer`
- Calls `StartupTasks.initIsolateServices()` to re-init services in new isolate
- Listens to `pushService.isSyncing`; forwards status strings to all connected ports
- After sync completes, calls `mcs.invokeMethod("exit")` to shut down isolate

### Video Compression

On Android send path, if attachment is video and size exceeds 100 MB, FFmpeg runs **synchronously on send path**:

```dart
await FFmpegKit.execute("-i \"$inputPath\" \"$outputPath\"");
```

Blocks calling async context until FFmpeg completes. Large videos cause noticeable delay before send API called.

### Link Metadata Fetch

Before `api.send()` for message containing URL, `RustPushBackend.sendMessage()` makes **3 sequential HTTP calls**:

1. `GET {url}/favicon.ico` — fetch favicon
2. `GET {metadata.image}` — fetch OG image bytes
3. `MetadataHelper.fetchMetadata(m)` — fetch title/description/URL

All three `await`ed sequentially with 15-second timeout each — up to 45 seconds potential latency before message is sent.

---

## `SyncService`

**File:** `lib/services/backend/sync/sync_service.dart`  
**Type:** `GetxService`

Manages BB server sync (not CloudKit). Used only in BlueBubbles-server mode.

### `startFullSync()`

Creates and runs `FullSyncManager`. Fetches pages of chats sequentially, then message pages per chat. Batch sizes: 200 chats/page, 25 messages/page.

### `startIncrementalSync()`

- **Mobile:** spawns `FlutterIsolate` running `incrementalSyncIsolate()`
- **Desktop:** runs `IncrementalSyncManager` directly on main Dart isolate — **blocks UI**

### `incrementalSyncIsolate()`

Re-inits all services in new isolate (`initIncrementalSyncServices()`), runs `IncrementalSyncManager`. Communicates completion back via `IsolateNameServer`.

---

## `FullSyncManager`

**File:** `lib/services/backend/sync/full_sync_manager.dart`

- Double-nested streaming: outer stream pages chats, inner stream pages messages per chat
- Fully sequential — no concurrent chat/message fetching
- Calls `formatPhoneNumber()` per chat handle during processing

---

## `IncrementalSyncManager`

**File:** `lib/services/backend/sync/incremental_sync_manager.dart`

3 server-version-gated code paths based on server API version.

**Known issues:**
- `syncedChats: Map<String, Chat>` accumulates **all** synced chats in memory — never cleared during sync run
- Operator precedence null-crash bug in timestamp tracking: `lastSyncedAt = lastSyncedAt ?? message.dateCreated?.millisecondsSinceEpoch` can null-crash under certain operator precedence combinations with null checks

---

## `ChatSyncManager`

**File:** `lib/services/backend/sync/chat_sync_manager.dart`

- Sequential `await Chat.getIcon()` calls **inside stream loop** — each awaits network request before processing next chat
- Serializes all group icon fetches; slow for large chat lists

---

## `HandleSyncManager`

**File:** `lib/services/backend/sync/handle_sync_manager.dart`

**Known issues / behaviors:**
- **Destructive clear:** drops entire handles table before streaming new handles from server — if stream fails mid-way, handles partially lost
- Per-handle sequential `formatPhoneNumber()` + `matchHandleToContact()` calls inside stream loop
- Uses `Map<Chat, List<int>>` with `Chat` objects as map keys — relies on object identity, not GUID equality; unexpected behavior if chat objects re-fetched between operations

---

## `ActionHandler`

**File:** `lib/services/backend/action_handler.dart`  
**Global accessor:** `ah`

Handles outbound message orchestration.

### `handledNewMessages` deduplication

```dart
final List<String> handledNewMessages = [];

bool shouldNotifyForNewMessageGuid(String guid) {
    if (handledNewMessages.contains(guid)) return false;
    handledNewMessages.add(guid);
    if (handledNewMessages.length > 100) {
        handledNewMessages.removeRange(0, handledNewMessages.length - 100);
    }
    return true;
}
```

- Capped at 100 entries
- Uses `List.contains()` — **O(n) linear scan** on every incoming message
- `removeRange(0, length - 100)` trims from front — O(n) shift

### Out-of-order self-sent messages

When self-sent SMS arrives before send confirmation:

```dart
await Future.delayed(const Duration(milliseconds: 500));
```

500 ms artificial delay inserted to allow send confirmation to arrive first and prevent duplicate messages in UI.

### FaceTime Poster Rendering

FaceTime incoming call posters rendered **on main isolate** using `Canvas`/`Picture`/`toByteData()`. Synchronous raster operation on UI thread.

---

## `LifecycleService`

**File:** `lib/services/backend/lifecycle/lifecycle_service.dart`  
**Global accessor:** `ls`

### `isAlive` Property

```dart
bool get isAlive =>
    AppLifecycleState == AppLifecycleState.resumed ||
    IsolateNameServer.lookupPortByName('bg_isolate') != null;
```

App considered "alive" (UI accessible) if either:
1. Flutter app in foreground (`resumed` state), **or**
2. Port named `'bg_isolate'` registered in `IsolateNameServer`

### `createFakePort()` Trick

Synthetic port registered under `'bg_isolate'` makes `isAlive` return `true` even when app not in foreground. Used by background services to prevent "failed to send" notifications while processing in background.

### `handleForegroundService()`

Arbitrates between `SocketIOForegroundService` (BB server keepalive) and app foreground state:
- App in foreground → stops foreground service
- App moves to background with `keepAppAlive == true` → starts foreground service
