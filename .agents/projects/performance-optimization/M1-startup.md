# M1 — Startup Time & Ready Signal

**Theme:** Reduce cold-start from 60–180s to <5s  
**Status:** Proposed  
**ADRs:** [ADR-001](../../adrs/ADR-001-parallel-icloud-init.md), [ADR-002](../../adrs/ADR-002-tokio-worker-threads.md), [ADR-003](../../adrs/ADR-003-async-file-io.md), [ADR-004](../../adrs/ADR-004-binary-plist.md)

---

## Task 1.1 — Parallelize iCloud Service Initialization

**Severity:** 🔴 Critical  
**Effort:** Medium  
**ADR:** [ADR-001](../../adrs/ADR-001-parallel-icloud-init.md)

**Files:**
- `rust/src/api/api.rs` — `SharedPushState::restore()`

**Problem:** CloudKit, Keychain, Passwords, Find My, SharedStreams, StatusKit, FaceTime initialized sequentially. Each needs network round-trip. Entire chain must complete before `native_ready` fires to Dart — causes multi-minute cold starts on poor connections.

**Solution:**
1. Split `restore()` into two phases:
   - **Phase 1 (critical path):** APSConnection + IMClient + Anisette. Fire `native_ready` after Phase 1.
   - **Phase 2 (background):** All iCloud services in parallel via `tokio::try_join!`.
2. Group independent iCloud services:
   ```rust
   let (cloudkit, keychain, passwords) = tokio::try_join!(
       make_cloudkit(&account, ...),
       make_keychain(&account, ...),
       make_passwords(&account, ...),
   )?;
   let (findmy, streams, statuskit) = tokio::try_join!(
       make_findmy(&account, ...),
       make_shared_streams(&account, ...),
       make_statuskit(&account, ...),
   )?;
   ```

**Acceptance Criteria:**
- [ ] `native_ready` fires within 5 seconds of launch on 4G
- [ ] iCloud services continue initializing after ready signal
- [ ] No regression in iCloud feature availability once Phase 2 completes

---

## Task 1.2 — Increase Tokio Worker Thread Count

**Severity:** 🔴 Critical  
**Effort:** Low  
**ADR:** [ADR-002](../../adrs/ADR-002-tokio-worker-threads.md)

**Files:**
- `rust/src/lib.rs`

**Problem:** `worker_threads(1)` serializes all Rust async work. Any blocking op stalls message delivery.

**Solution:**
```rust
// rust/src/lib.rs
.worker_threads(
    std::thread::available_parallelism()
        .map(|n| n.get().min(4))
        .unwrap_or(2)
)
```
Cap at 4 to avoid over-subscribing low-end CPUs.

**Acceptance Criteria:**
- [x] Multiple iCloud service handlers run concurrently
- [x] No single slow handler blocks iMessage delivery
- [x] CPU core count respected (capped at 4)

---

## Task 1.3 — Replace Blocking File I/O with `tokio::fs`

**Severity:** 🔴 Critical  
**Effort:** Low  
**ADR:** [ADR-003](../../adrs/ADR-003-async-file-io.md)

**Files:**
- `rust/src/api/api.rs` — lines 459, 871, 897, 914 and `update_keys` callback

**Problem:** `std::fs::write` and `plist_to_file_xml` are sync blocking calls inside async tasks. Block Tokio executor from processing other events during OS write.

**Solution:**
```rust
// Before:
std::fs::write(&state_path, plist_to_string(&state).unwrap()).unwrap();

// After:
tokio::fs::write(&state_path, plist_to_string(&state)?).await?;
```

For `update_keys` closure (passed as sync callback), wrap in `tokio::spawn`:
```rust
let path = path.clone();
move |keys| {
    let keys = keys.clone();
    tokio::spawn(async move {
        tokio::fs::write(&path, serialize_keys(&keys)).await
            .unwrap_or_else(|e| log::error!("key save failed: {e}"));
    });
}
```

**Acceptance Criteria:**
- [x] No `std::fs::read` or `std::fs::write` inside async functions in `api.rs`
- [x] All file writes use `tokio::fs` or spawned onto blocking thread pool
- [x] File write errors logged, not panicked

---

## Task 1.4 — Replace XML Plist with Binary Format for State Persistence

**Severity:** 🟠 High  
**Effort:** Medium  
**ADR:** [ADR-004](../../adrs/ADR-004-binary-plist.md)

**Files:**
- `rust/src/api/api.rs` — all `plist_to_string` / `plist_to_file_xml` call sites

**Problem:** All on-disk state serialized as verbose XML plist. Binary plist is 40–70% smaller and 5–10× faster to serialize/deserialize.

**Solution:**
1. Switch writes to `plist::to_writer_binary`.
2. Read path (`plist::from_file`) already handles both formats — backward compatible.
3. On first open after migration, re-serialize existing XML files to binary (one-time migration in `migrate()`).

**Acceptance Criteria:**
- [ ] All new state files written as binary plist
- [ ] Existing XML files migrated on first open
- [ ] Reads succeed on both old XML and new binary files
- [ ] State file sizes measurably smaller

---

## Task 1.5 — Defer ML Kit Entity Extractor Download

**Severity:** 🟡 Medium  
**Effort:** Low  

**Files:**
- `lib/main.dart`

**Problem:** ML Kit entity extractor model downloaded at startup on Android, adding to initial boot delay.

**Solution:** Move download trigger to `Future.delayed(Duration.zero)` after first conversation list frame renders (post-frame callback), not inline in `initApp()`.

**Acceptance Criteria:**
- [ ] Startup no longer blocks on ML model download
- [ ] Model available by time user opens conversation
