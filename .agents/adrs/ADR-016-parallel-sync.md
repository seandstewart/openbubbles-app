# ADR-016 — Concurrent Chat and Handle Sync Operations

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M6-sync.md)

## Context

Three sync operations currently fully sequential:

1. **`FullSyncManager`**: Iterates chat pages, then for each chat iterates message pages. 200 chats × 3 message pages = 600 sequential HTTP calls. ~200ms RTT each = ~120s minimum.

2. **`HandleSyncManager`**: Per handle: `await formatPhoneNumber(handle.address)` + `await matchHandleToContact(handle.address)`. 3,000 handles → 6,000 sequential async ops.

3. **`ChatSyncManager`**: `await Chat.getIcon(chat)` per group chat inside stream loop, blocking page processing per icon fetch.

Operations are independent per entity — no data dependency between syncing chat A's messages and chat B's messages.

## Decision

**`FullSyncManager`:** Fetch chat pages sequentially (maintain pagination order). Within each page, fetch messages for all chats concurrently with bounded limit:

```dart
const _concurrentChatFetches = 5;

await for (final chatPage in _streamChatPages(batchSize: 200)) {
  for (final chunk in chatPage.slices(_concurrentChatFetches)) {
    await Future.wait(chunk.map(_fetchAndSaveMessages));
  }
}
```

**`HandleSyncManager`:** After loading each page, process all handles concurrently:

```dart
await for (final page in _streamHandlePages(batchSize: 200)) {
  await Future.wait(page.map((h) async {
    h.formattedAddress = await formatPhoneNumber(h.address);
    h.contact = cs.matchHandleToContact(h.address); // O(1) with ADR-007
  }));
  Database.handles.putMany(page);
}
```

**`ChatSyncManager`:** Collect group chats per page, fetch icons concurrently:

```dart
await for (final page in _streamChatPages(batchSize: 100)) {
  await _saveChatPage(page);
  await Future.wait(
    page.where((c) => c.isGroup).map((c) => Chat.getIcon(c, force: false))
  );
}
```

## Consequences

**Positive:**
- Full sync for 200 chats: ~120s → ~30s (5x concurrent chat fetches)
- Handle sync for 3,000 handles: minutes → seconds
- Group icon fetches no longer serialize page processing

**Negative:**
- Concurrent HTTP requests increase peak bandwidth — bounded by concurrency limits (5 max)
- Error in one concurrent chat fetch must not abort others; each `_fetchAndSaveMessages` must handle own errors

## Alternatives Considered

**A: Full parallelism with `Future.wait` across all chats**  
Risk of overwhelming server with 200 simultaneous requests. Bounded concurrency (5) safer.

**B: Use Dart isolates for sync**  
Sync is I/O-bound (HTTP), not CPU-bound. `async/await` concurrency sufficient; isolates add complexity without benefit.
