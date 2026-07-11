# ADR-011 — Cancel Retry Tasks on Message Acknowledgement

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M2-message-delivery.md)

## Context

In `rust/src/native.rs`, `NativePushState::start_loop()` spawns a retry task per received message:

```rust
let key = /* message key */;
QUEUED_MESSAGES.lock().unwrap().insert(key, (msg, 0));
handler.receieved_msg(key, 0);

// Retry task — never cancelled
tokio::spawn(async move {
    for retry in 1..=5u8 {
        tokio::time::sleep(Duration::from_secs(30)).await;
        let guard = QUEUED_MESSAGES.lock().unwrap();
        if guard.contains_key(&key) {
            drop(guard);
            handler.receieved_msg(key, retry);
        } else {
            break; // Dart consumed the message
        }
    }
});
```

When Dart acks a message (`get_msg(key)`), it's removed from `QUEUED_MESSAGES`. Retry task checks `contains_key` before re-emitting — won't send stale messages — but keeps sleeping 30s between checks, acquiring mutex each iteration.

Burst of 100 messages → 100 retry tasks simultaneously, 500 mutex acquisitions over 2.5 min, all for tasks that should've been cancelled.

## Decision

Store `tokio::task::AbortHandle` alongside each queued message:

```rust
struct QueuedEntry {
    message: PushMessage,
    retry: u8,
    abort: AbortHandle,
}

// In start_loop:
let (abort, reg) = AbortHandle::new_pair();
let task = tokio::spawn(Abortable::new(retry_future, reg));
QUEUED_MESSAGES.lock().unwrap().insert(key, QueuedEntry { message: msg, retry: 0, abort });

// In get_msg (called when Dart dequeues):
if let Some(entry) = QUEUED_MESSAGES.lock().unwrap().remove(&key) {
    entry.abort.abort(); // cancel the retry task
    Some(entry.message)
} else {
    None
}
```

Add max queue depth of 500 entries. When exceeded, oldest entry's retry task is aborted and entry dropped.

## Consequences

**Positive:**
- Retry task count drops to 0 when Dart is responsive
- Mutex acquisition rate proportional to active message count, not historical volume
- Queued message memory bounded (500 entries max)

**Negative:**
- `AbortHandle` / `Abortable` adds small per-task allocation
- If `get_msg` never called (Dart crash), messages still expire after 5 × 30s = 2.5 min — same as before

## Alternatives Considered

**A: Replace retry tasks with single periodic sweeper task**  
One task wakes every 30s, re-emits all queued messages. Simpler but can't differentiate messages needing earlier vs later retry.

**B: Use channel for cancel signal**  
`tokio::sync::oneshot` for cancel — equivalent to `AbortHandle` but more verbose.
