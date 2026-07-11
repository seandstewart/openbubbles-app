# OpenBubbles — Agent Guide

All agent resources are located in [`.agents/`](.agents/).

## Directory Index

| Directory | Purpose |
|---|---|
| [`.agents/rules/`](.agents/rules/) | Coding and process rules agents must follow |
| [`.agents/reference/`](.agents/reference/) | Codebase implementation details and architecture docs |
| [`.agents/projects/`](.agents/projects/) | Active and planned project work with discrete tasks |
| [`.agents/adrs/`](.agents/adrs/) | Architecture Decision Records for all significant changes |
| [`.agents/skills/`](.agents/skills/) | Reusable agent skill definitions |

## Rules

| File | Applies To |
|---|---|
| [`.agents/rules/adr.md`](.agents/rules/adr.md) | When and how to write Architecture Decision Records |
| [`.agents/rules/project-planning.md`](.agents/rules/project-planning.md) | How to structure projects and milestone files |
| [`.agents/rules/caveman.md`](.agents/rules/caveman.md) | Caveman mode always on — terse responses by default |

## Reference Documentation

| File | Covers |
|---|---|
| [`.agents/reference/architecture.md`](.agents/reference/architecture.md) | Overall 4-layer architecture, tech stack, global singletons, entry points |
| [`.agents/reference/rust-backend.md`](.agents/reference/rust-backend.md) | Tokio runtime, SharedPushState, recv_wait, FFI bridge, keystore |
| [`.agents/reference/flutter-services.md`](.agents/reference/flutter-services.md) | RustPushService, sync managers, ActionHandler, CloudKit, LifecycleService |
| [`.agents/reference/flutter-ui.md`](.agents/reference/flutter-ui.md) | Widget tree, GetX controllers, event bus, caching, ObjectBox watcher patterns |
| [`.agents/reference/android-native.md`](.agents/reference/android-native.md) | APNService, DartWorker, notification pipeline, lifecycle, broadcast receivers |
| [`.agents/reference/database.md`](.agents/reference/database.md) | ObjectBox schema, Box accessors, query patterns, watcher usage, sync helpers |

## Active Projects

| Project | Goal | Status |
|---|---|---|
| [Performance Optimization](.agents/projects/performance-optimization/README.md) | Eliminate bottlenecks for low-end Android devices | Proposed |

## Architecture Decision Records

All ADRs are in [`.agents/adrs/`](.agents/adrs/). See [`.agents/rules/adr.md`](.agents/rules/adr.md) for when and how to write them.

| ADR | Decision | Status |
|---|---|---|
| [ADR-001](.agents/adrs/ADR-001-parallel-icloud-init.md) | Parallelize iCloud service initialization | Proposed |
| [ADR-002](.agents/adrs/ADR-002-tokio-worker-threads.md) | Increase Tokio worker thread count | Proposed |
| [ADR-003](.agents/adrs/ADR-003-async-file-io.md) | Replace blocking file I/O with tokio::fs | Proposed |
| [ADR-004](.agents/adrs/ADR-004-binary-plist.md) | Replace XML plist with binary plist | Proposed |
| [ADR-005](.agents/adrs/ADR-005-batch-message-watcher.md) | Batch message ObjectBox watcher | Proposed |
| [ADR-006](.agents/adrs/ADR-006-globalchatservice-delta.md) | GlobalChatService delta-based updates | Proposed |
| [ADR-007](.agents/adrs/ADR-007-contact-phone-index.md) | Contact phone number index | Proposed |
| [ADR-008](.agents/adrs/ADR-008-lru-image-cache.md) | LRU eviction for image cache | Proposed |
| [ADR-009](.agents/adrs/ADR-009-dpoll-backoff.md) | Exponential backoff in doPoll() | Proposed |
| [ADR-010](.agents/adrs/ADR-010-parallel-handler-dispatch.md) | Parallel handler dispatch in recv_wait | Proposed |
| [ADR-011](.agents/adrs/ADR-011-retry-task-cancellation.md) | Cancel retry tasks on message ACK | Proposed |
| [ADR-012](.agents/adrs/ADR-012-parallel-avatar-loading.md) | Parallel contact avatar loading | Proposed |
| [ADR-013](.agents/adrs/ADR-013-mlkit-off-build-path.md) | ML Kit off widget build path | Proposed |
| [ADR-014](.agents/adrs/ADR-014-chunked-cloudkit-erase.md) | Chunked CloudKit sync erasure | Proposed |
| [ADR-015](.agents/adrs/ADR-015-avatar-file-uri.md) | Notification avatars by file URI | Proposed |
| [ADR-016](.agents/adrs/ADR-016-parallel-sync.md) | Concurrent chat and handle sync | Proposed |
| [ADR-017](.agents/adrs/ADR-017-db-transactions.md) | Explicit ObjectBox write transactions | Proposed |
| [ADR-018](.agents/adrs/ADR-018-desktop-key-security.md) | Platform keychain for desktop encryption | Proposed |
