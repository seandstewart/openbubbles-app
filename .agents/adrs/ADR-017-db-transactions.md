# ADR-017 — Wrap Sync DB Writes in Explicit ObjectBox Transactions

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M6-sync.md)

## Context

`sync_helpers.dart` performs multiple `putMany()` calls in one logical sync operation:

```dart
Database.messages.putMany(newMessages);           // transaction 1
Database.messages.putMany(updatedMessages, mode: PutMode.update); // transaction 2
// Re-query for chat matching
Database.messages.putMany(relinkedMessages);      // transaction 3
// Retry loop
Database.messages.putMany(retryMessages);         // transaction 4
```

Each `putMany()` is an implicit ObjectBox transaction with full commit (fsync). For 3,000 messages: 4 fsyncs to same file. On Android ext4/f2fs, each fsync takes 5–50ms → 20–200ms unnecessary overhead per sync batch.

## Decision

Wrap entire logical sync sequence in single explicit `Database.store.runInTransaction(TxMode.write, ...)`:

```dart
Database.store.runInTransaction(TxMode.write, () {
  // Step 1: save new messages
  final newIds = Database.messages.putMany(newMessages);
  
  // Step 2: update existing
  Database.messages.putMany(updatedMessages, mode: PutMode.update);
  
  // Step 3: re-link to chats (can query within the transaction)
  final relinked = _buildChatRelations(newMessages, newIds);
  Database.messages.putMany(relinked, mode: PutMode.update);
});
```

ObjectBox transactions are ACID, support reads and writes within single transaction.

**Note:** Queries within write transaction see transaction's own writes (snapshot isolation). Retry loop pattern (re-query, re-link) works correctly within single transaction.

## Consequences

**Positive:**
- 4 fsyncs per batch → 1 fsync
- Sync write throughput increases 3–4x for large batches
- Atomicity: all 3,000 messages saved or none (no partial sync inconsistency)

**Negative:**
- Long-running write transaction blocks concurrent read transactions (ObjectBox MVCC; readers see stale data until commit)
- No async `await` inside `runInTransaction()` — ObjectBox transactions are synchronous

## Alternatives Considered

**A: Use ObjectBox async transaction API**  
ObjectBox Dart doesn't expose async write transactions. Sync helpers are synchronous — no issue.

**B: Batch with fewer putMany calls (combine new + updated)**  
Reduces transaction count slightly but doesn't eliminate per-`putMany` overhead as cleanly.
