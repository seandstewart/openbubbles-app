# M2 — Message Delivery Pipeline

**Theme:** Fast, gap-free, crash-safe message delivery  
**Status:** Proposed  
**ADRs:** [ADR-009](../../adrs/ADR-009-dpoll-backoff.md), [ADR-010](../../adrs/ADR-010-parallel-handler-dispatch.md), [ADR-011](../../adrs/ADR-011-retry-task-cancellation.md)

---

## Task 2.1 — Add Error Backoff and Reconnect to `doPoll()`

**Severity:** 🔴 Critical  
**Effort:** Low  
**ADR:** [ADR-009](../../adrs/ADR-009-dpoll-backoff.md)

**Files:**
- `lib/services/rustpush/rustpush_service.dart` — `doPoll()`

**Problem:** If `api.recvWait()` returns without blocking (e.g., silent connection error), `while(true)` loop spins at full CPU indefinitely.

**Solution:**
```dart
int _backoffMs = 100;

Future<void> doPoll() async {
  while (true) {
    try {
      final res = await api.recvWait(...);
      _backoffMs = 100;
      await handleMsg(res);
    } catch (e, s) {
      Logger.error('recvWait error', error: e, trace: s);
      await Future.delayed(Duration(milliseconds: _backoffMs));
      _backoffMs = (_backoffMs * 2).clamp(100, 30000);
    }
  }
}
```

**Acceptance Criteria:**
- [ ] CPU does not spike during APNs connection errors
- [ ] Reconnect backoff caps at 30 seconds
- [ ] Errors logged with stack trace

---

## Task 2.2 — Parallelize Per-Message Handler Dispatch

**Severity:** 🟠 High  
**Effort:** Medium  
**ADR:** [ADR-010](../../adrs/ADR-010-parallel-handler-dispatch.md)

**Files:**
- `rust/src/api/api.rs` — `recv_wait()` select loop (lines 1738–1839)

**Problem:** Each APS message dispatched to 7 service handlers in strict sequence. Slow handler (e.g., `fmfd.handle()` with network call) blocks iMessage delivery.

**Solution:** Use `tokio::task::JoinSet` to dispatch all handlers concurrently:
```rust
let mut set = JoinSet::new();
set.spawn(async move { fmfd.handle(msg.clone()).await });
set.spawn(async move { photostream.handle(msg.clone()).await });
set.spawn(async move { statuskit.handle(msg.clone()).await });
set.spawn(async move { passwords.handle(msg.clone()).await });
set.spawn(async move { idms_client.handle(msg.clone()).await });
set.spawn(async move { ft_client.handle(msg.clone()).await });
set.spawn(async move { client.handle(msg).await });

while let Some(result) = set.join_next().await {
    if let Ok(Ok(PollResult::Cont(push_msg))) = result {
        // queue the message
    }
}
```

**Note:** Requires Task 1.2 (multiple Tokio worker threads) for actual parallelism.

**Acceptance Criteria:**
- [ ] All 7 handlers run concurrently per APS message
- [ ] Slow handlers (Find My, photostream) do not delay iMessage delivery
- [ ] Handler errors caught per-handler and logged, not propagated to kill loop

---

## Task 2.3 — Cap Queue and Cancel Retry Tasks on ACK

**Severity:** 🟠 High  
**Effort:** Low  
**ADR:** [ADR-011](../../adrs/ADR-011-retry-task-cancellation.md)

**Files:**
- `rust/src/native.rs` — `start_loop()`, `QUEUED_MESSAGES`

**Problem:** Retry tasks (30s × 5 retries) never cancelled when Dart acknowledges message. Under high volume, tasks accumulate — each polling shared mutex every 30 seconds.

**Solution:**
1. Store `tokio::task::AbortHandle` alongside each queued message.
2. Cancel handle when message dequeued.
3. Add max queue depth of 500; evict oldest when exceeded.

```rust
struct QueuedMessage {
    message: PushMessage,
    retry: u8,
    abort: AbortHandle,
}
// In dequeue:
if let Some(qm) = QUEUED_MESSAGES.lock().unwrap().remove(&key) {
    qm.abort.abort();
}
```

**Acceptance Criteria:**
- [ ] Retry task count drops to zero when Dart is responsive
- [ ] Queue depth never exceeds 500 entries
- [ ] Cancelled tasks do not log errors

---

## Task 2.4 — Fix `RUNTIME.block_on()` Deadlock in `get_auth_code`

**Severity:** 🟡 Medium  
**Effort:** Low  

**Files:**
- `rust/src/native.rs` — `get_auth_code()` (line 352)

**Problem:** `RUNTIME.block_on(...)` called from thread that may already be inside Tokio runtime — deadlocks thread.

**Solution:**
```rust
// Before:
RUNTIME.block_on(async { ... })

// After:
tokio::task::block_in_place(|| RUNTIME.block_on(async { ... }))
```
`block_in_place` moves calling thread out of async executor temporarily, making `block_on` safe.

**Acceptance Criteria:**
- [ ] 2FA auth code retrieval does not deadlock
- [ ] Unit test added covering `get_auth_code` call path from Tokio task

---

## Task 2.5 — Fix `Thread.sleep` ANR in `SocketIOForegroundService`

**Severity:** 🔴 Critical  
**Effort:** Low  

**Files:**
- `android/app/src/main/kotlin/com/bluebubbles/messaging/services/foreground/SocketIOForegroundService.kt` — `tryReconnect()`

**Problem:** `Thread.sleep(30000)` on Service main thread blocks all service callbacks for 30 seconds — ANR-class bug.

**Solution:**
```kotlin
// Before:
fun tryReconnect() {
    Thread.sleep(30000)
    mSocket!!.connect()
}

// After:
fun tryReconnect() {
    scope.launch {
        delay(30_000)
        mSocket?.connect()
    }
}
```
Where `scope` is existing `CoroutineScope(Dispatchers.IO + SupervisorJob())`.

**Acceptance Criteria:**
- [ ] `SocketIOForegroundService` never blocks main thread
- [ ] Reconnect still occurs after 30 seconds
- [ ] No ANR in reconnect path on any Android version
