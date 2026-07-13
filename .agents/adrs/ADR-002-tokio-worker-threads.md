# ADR-002 — Increase Tokio Runtime Worker Thread Count

**Status:** Implemented
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M1-startup.md)

## Context

Global Tokio runtime in `rust/src/lib.rs` is initialized with `worker_threads(1)`. Every async task — iMessage processing, FaceTime, Find My, iCloud Keychain, attachment downloads, key ops — serialized on one OS thread.

With ADR-010 (parallel handler dispatch), each incoming APS message spawns tasks for up to 7 handlers. Without multiple worker threads, tasks execute sequentially despite being spawned into a `JoinSet`. Slow handler (e.g., 2s Find My API call) blocks iMessage delivery for that duration.

No correctness impact: all state in `SharedPushState` already protected by `Arc<Mutex<T>>` or `Arc<RwLock<T>>`.

## Decision

Replace hardcoded `worker_threads(1)` with runtime-detected value, capped at 4:

```rust
.worker_threads(
    std::thread::available_parallelism()
        .map(|n| n.get().min(4))
        .unwrap_or(2)
)
```

**Rationale for cap of 4:**
- Low-end Android devices typically have 4–8 cores, many efficiency cores. Cap at 4 avoids starving UI thread and system processes.
- Tokio's work-stealing scheduler is efficient; 2–4 threads provide sufficient parallelism for workload (7 concurrent handlers + background tasks).
- Beyond 4 threads, marginal benefit decreases while scheduler overhead increases.

## Consequences

**Positive:**
- Handler dispatch (ADR-010) achieves actual parallelism
- Slow iCloud service calls don't delay iMessage delivery
- Attachment downloads and message sending can proceed concurrently

**Negative:**
- Slightly higher memory per additional thread (stack allocation)
- On single-core devices (rare, Android Go), `available_parallelism()` returns 1, runtime stays at 1 thread — acceptable fallback

## Alternatives Considered

**A: Keep 1 thread, fix root cause in each slow handler**  
Partially valid but insufficient. Some handlers (e.g., Find My) make external network calls with uncontrollable latency. True parallelism requires multiple threads.

**B: Use `current_thread` runtime for lightweight tasks + `tokio::task::spawn_blocking` for blocking tasks**  
More complex. Current architecture mixes blocking and non-blocking work freely; migrating to `spawn_blocking` at each call site is larger refactor. Multi-thread runtime is pragmatic choice.
