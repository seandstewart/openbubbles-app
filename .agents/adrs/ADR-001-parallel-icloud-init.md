# ADR-001 — Parallel iCloud Service Initialization

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M1-startup.md)

## Context

`SharedPushState::restore()` in `rust/src/api/api.rs` initializes all iCloud services (CloudKit, Keychain, Passwords, Find My, SharedStreams, StatusKit, FaceTime) sequentially. Each requires at least one network round-trip to Apple's servers. Chain must complete before `native_ready` is called, which unblocks Flutter UI.

On 4G with 200ms RTT, chain takes 10–30s. Poor connections or Apple slowdowns can exceed 60s. Primary cause of multi-minute cold-start.

iMessage core (APSConnection + IMClient) does not depend on iCloud services being initialized first.

## Decision

Split `SharedPushState::restore()` into two phases:

**Phase 1 (critical path, sequential):**
1. `init_keystore`
2. `migrate()`
3. `read_hardware` / identity restore
4. `setup_push` → APSConnection
5. `make_imclient` → IMClient
6. `make_anisette`
7. `restore_account` → AppleAccount
8. Signal `native_ready` to Dart/Kotlin

**Phase 2 (background, parallel via `tokio::try_join!`):**
```rust
let (cloudkit, keychain, passwords) = tokio::try_join!(
    make_cloudkit(&account, ...),
    make_keychain(&account, ...),
    make_passwords(&account, ...),
)?;
let (findmy, streams, statuskit, facetime) = tokio::try_join!(
    make_findmy(&account, ...),
    make_shared_streams(&account, ...),
    make_statuskit(&account, ...),
    make_ftclient(&account, ...),
)?;
```

Phase 2 runs after `native_ready` fires. Features dependent on iCloud services (Find My, Shared Albums, Keychain sync) become available progressively as each service completes.

Dart/Kotlin must handle services not yet ready by checking `Option<T>` on relevant `SharedPushState` fields.

## Consequences

**Positive:**
- Cold-start "app ready" time reduced from 10–60s to <5s
- App usable for iMessage immediately; iCloud features available in background
- Phase 2 services init in parallel, reducing total background time

**Negative:**
- UI must handle partial-availability state (e.g., Find My tab shows "loading" until ready)
- Error handling for Phase 2 failures must be decoupled from startup path
- `SharedPushState` fields for optional services become `Option<Arc<T>>` instead of `Arc<T>`, requiring null-checks at all call sites

## Alternatives Considered

**A: Keep sequential order, show progress spinner**  
Rejected. Doesn't fix core problem — app still unusable for 10–60s. Users abandon.

**B: Parallelize all services including APSConnection**  
Rejected. APSConnection and IMClient have strict dependency order (connection before client). Parallelizing requires complex coordination.

**C: Persist initialized service state to disk, skip re-init on subsequent launches**  
Partially applicable — app already caches some tokens. Full service-state caching is larger project; doesn't address first-launch.
