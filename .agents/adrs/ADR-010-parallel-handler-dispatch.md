# ADR-010 — Parallel Handler Dispatch in `recv_wait()`

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M2-message-delivery.md)

## Context

`recv_wait()` in `rust/src/api/api.rs` dispatches each incoming APS push to 7 service handlers in strict sequence:

```rust
let r = fmfd.handle(msg.clone()).await;
let r = photostream.handle(msg.clone()).await;
let r = statuskit.handle(msg.clone()).await;
let r = passwords.handle(msg.clone()).await;
let r = idms_client.handle(msg.clone()).await;
let r = ft_client.handle(msg.clone()).await;
let r = client.handle(msg).await; // IMClient — iMessage
```

Each handler checks relevance — most messages hit only one handler. Handlers are independent; output of one doesn't feed another.

If `fmfd.handle()` makes network call (e.g. Find My location update), it blocks iMessage delivery (`client.handle()`) for full duration.

## Decision

Dispatch all 7 handlers concurrently via `tokio::task::JoinSet`:

```rust
use tokio::task::JoinSet;

let mut set = JoinSet::new();

let fmfd = fmfd.clone();
let msg_clone = msg.clone();
set.spawn(async move { fmfd.handle(msg_clone).await });

// ... similarly for photostream, statuskit, passwords, idms, facetime ...

let client = client.clone();
set.spawn(async move { client.handle(msg).await });

let mut result = PollResult::Cont(None);
while let Some(res) = set.join_next().await {
    match res {
        Ok(Ok(PollResult::Cont(Some(push_msg)))) => {
            result = PollResult::Cont(Some(push_msg));
        }
        Err(e) => log::error!("Handler panicked: {e:?}"),
        _ => {}
    }
}
result
```

Requires ADR-002 (multiple Tokio worker threads) for OS-level parallelism.

All handler types must implement `Clone` (or be wrapped in `Arc`) to allow sharing across tasks.

## Consequences

**Positive:**
- Slow handlers (Find My, photostream) don't delay iMessage delivery
- Handler errors isolated per-task, logged without killing loop
- Total processing time = slowest handler, not sum of all

**Negative:**
- Each handler gets `msg.clone()` — 7 clones per APS message. `PushMessage` must be cheap to clone (should be `Arc`-wrapped)
- JoinSet adds minor overhead vs sequential — negligible vs handler latency

## Alternatives Considered

**A: Fire-and-forget for non-iMessage handlers, sequential for IMClient**  
Simpler but loses error reporting. Prevents collecting results if other handlers produce needed messages.

**B: Use `tokio::select!` macro**  
`select!` cancels remaining futures on first completion. Not suitable — all handlers must run to completion.
