# ADR-014 — Chunked CloudKit Sync ID Erasure

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M4-memory.md)

## Context

`eraseCloudKitSync()` in `rustpush_service.dart` clears CloudKit record IDs from all local entities:

```dart
final messages = Database.messages.getAll();       // ALL messages
final chats    = Database.chats.getAll();           // ALL chats
final attachments = Database.attachments.getAll(); // ALL attachments
// Clears ckRecordId on each, then putMany()
```

5 years of iMessage history: 50,000+ messages × 3 tables loaded simultaneously. On device with 2 GB RAM / ~800 MB available, this single operation can exhaust heap and trigger OOM kill.

## Decision

Process each table in chunks of 500 rows using ObjectBox's `Query.find(offset:, limit:)`:

```dart
Future<void> _clearCkRecordIds<T extends Object>(
  Box<T> box,
  void Function(T) clearFn,
) async {
  const chunkSize = 500;
  final query = box.query().build();
  try {
    int offset = 0;
    while (true) {
      final chunk = query.find(offset: offset, limit: chunkSize);
      if (chunk.isEmpty) break;
      for (final item in chunk) clearFn(item);
      box.putMany(chunk);
      offset += chunkSize;
      // Yield to event loop to allow GC between chunks
      await Future.delayed(Duration.zero);
    }
  } finally {
    query.close();
  }
}
```

## Consequences

**Positive:**
- Peak memory capped at ~500 entities per chunk (few MB)
- Operation completes on low-RAM devices
- `Future.delayed(Duration.zero)` yields allow GC to reclaim chunk memory between iterations

**Negative:**
- Operation takes longer (more DB round-trips) — acceptable for one-time reset
- Query must stay open across iterations — `query.close()` in `finally` ensures cleanup

## Alternatives Considered

**A: Use single SQL-style `UPDATE` query to clear field**  
ObjectBox doesn't support partial field updates without loading entity. Must load, modify, re-save.

**B: Delete and re-create entities without ckRecordId**  
Loses all other entity data. Not appropriate.
