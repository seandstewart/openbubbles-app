# ADR-003 — Replace Blocking File I/O with `tokio::fs` in Async Contexts

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M1-startup.md)

## Context

Several locations in `rust/src/api/api.rs` call `std::fs::write`, `plist_to_file_xml`, and similar sync file I/O inside `async fn` bodies or `tokio::spawn` closures:

- Line 459: `std::fs::write` inside `update_keys` callback (called from async context)
- Line 871: `plist_to_file_xml` inside spawned task
- Lines 897, 914: `std::fs::write` inside async init functions

These block the Tokio worker thread for the duration of the OS write syscall. With `worker_threads(1)` (current), this blocks all other async work, including message delivery, for potentially hundreds of milliseconds.

Even with ADR-002 (multiple worker threads), blocking file I/O wastes a Tokio worker thread that could be processing messages.

## Decision

Replace all `std::fs::*` and sync plist I/O calls inside async contexts with async equivalents:

```rust
// Before:
std::fs::write(&path, data).unwrap();

// After:
tokio::fs::write(&path, data).await?;
```

For `update_keys` callback (sync closure passed to `IMClient`), wrap in `tokio::spawn`:
```rust
move |keys| {
    let path = path.clone();
    let keys = serialize_keys(&keys);
    tokio::spawn(async move {
        if let Err(e) = tokio::fs::write(&path, keys).await {
            log::error!("Failed to save keys: {e}");
        }
    });
}
```

For plist ops with no async variant, use `tokio::task::spawn_blocking`:
```rust
let data = state_to_save.clone();
tokio::task::spawn_blocking(move || {
    plist::to_file_xml(&path, &data)
}).await??;
```

## Consequences

**Positive:**
- Tokio worker threads not blocked during file writes
- Message delivery unaffected by state persistence timing
- File I/O errors propagated as `Result` rather than panics

**Negative:**
- `spawn_blocking` adds thread-pool thread for blocking tasks — small overhead
- Async file I/O on some Android kernel versions has higher latency than sync for small writes — acceptable given benefit to message delivery

## Alternatives Considered

**A: Move all file I/O to dedicated `std::thread` writer with channel**  
Overcomplicated. `tokio::fs` and `spawn_blocking` achieve same goal with less code.

**B: Accept blocking I/O, increase worker threads to compensate**  
Not acceptable — wastes threads, doesn't eliminate blocking.
