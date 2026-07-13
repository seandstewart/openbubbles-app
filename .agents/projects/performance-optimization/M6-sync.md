# M6 — Sync Performance

**Theme:** Faster initial & incremental sync  
**Status:** In Progress (M6.2 ✅)
**ADRs:** [ADR-016](../../adrs/ADR-016-parallel-sync.md), [ADR-017](../../adrs/ADR-017-db-transactions.md)

---

## Task 6.1 — Parallelize Full Sync Chat Fetching

**Severity:** 🟠 High  
**Effort:** Medium  
**ADR:** [ADR-016](../../adrs/ADR-016-parallel-sync.md)

**Files:**
- `lib/services/backend/sync/full_sync_manager.dart`

**Problem:** Full sync is sequential double-nested loop: pages of chats → per-chat message pages. 200 chats × 3 pages = 600 sequential HTTP calls.

**Solution:** Fetch all chat pages sequentially (preserve pagination order), then fetch messages for all chats in page concurrently (bounded concurrency):
```dart
const _maxConcurrentChatFetches = 5;
await for (final chatPage in _streamChatPages()) {
  final chunks = chatPage.slices(_maxConcurrentChatFetches);
  for (final chunk in chunks) {
    await Future.wait(chunk.map(_syncChatMessages));
  }
}
```

**Acceptance Criteria:**
- [ ] Full sync duration decreases by ≥50% for users with 100+ chats
- [ ] Pagination order preserved (no duplicate or skipped messages)
- [ ] Network errors in one chat do not abort entire sync

---

## Task 6.2 — Parallelize Handle Sync Phone Formatting and Contact Matching

**Severity:** 🟠 High  
**Effort:** Low  

**Files:**
- `lib/services/backend/sync/handle_sync_manager.dart`

**Problem:** `formatPhoneNumber()` and `matchHandleToContact()` awaited sequentially per handle inside streaming loop.

**Solution:**
```dart
await for (final page in _streamHandlePages()) {
  await Future.wait(page.map((handle) async {
    handle.formattedAddress = await formatPhoneNumber(handle.address);
    handle.contact = cs.matchHandleToContact(handle.address); // O(1) after Task 3.3
  }));
  Database.handles.putMany(page);
}
```

**Acceptance Criteria:**
- [x] Handle sync time decreases proportionally to concurrency
- [x] Formatted addresses consistent with sequential version

---

## Task 6.3 — Wrap Sync DB Writes in Explicit Transactions

**Severity:** 🟡 Medium  
**Effort:** Low  
**ADR:** [ADR-017](../../adrs/ADR-017-db-transactions.md)

**Files:**
- `lib/database/` — `sync_helpers.dart`

**Problem:** `syncMessages` calls `putMany()` up to 4 times, each as separate ObjectBox transaction with individual commit overhead.

**Solution:**
```dart
Database.store.runInTransaction(TxMode.write, () {
  Database.messages.putMany(newMessages);
  Database.messages.putMany(updatedMessages, mode: PutMode.update);
  // re-link and re-put
});
```

**Acceptance Criteria:**
- [ ] Each sync batch is single ObjectBox transaction
- [ ] Sync write throughput increases measurably

---

## Task 6.4 — Fix `syncedChats` Unbounded Memory Growth

**Severity:** 🟡 Medium  
**Effort:** Low  

**Files:**
- `lib/services/backend/sync/incremental_sync_manager.dart`

**Problem:** `syncedChats: Map<String, Chat>` accumulates all synced chats across pages. O(total chats) memory for large syncs.

**Solution:** Retain only GUIDs during streaming; load full chat objects from DB at end:
```dart
final syncedGuids = <String>{};
await for (final page in _syncPages()) {
  await _processPage(page);
  syncedGuids.addAll(page.map((c) => c.guid));
}
final chats = Database.chats
    .query(Chat_.guid.oneOf(syncedGuids.toList()))
    .build().find();
await Chat.syncLatestMessages(chats, true);
```

**Acceptance Criteria:**
- [ ] In-memory chat accumulation is O(page size) during streaming
- [ ] `syncLatestMessages` call still receives correct chat list

---

## Task 6.5 — Parallelize Group Icon Fetches in Chat Sync

**Severity:** 🟠 High  
**Effort:** Low  

**Files:**
- `lib/services/backend/sync/chat_sync_manager.dart`

**Problem:** `await Chat.getIcon(chat)` called inside stream loop per group chat, blocking each page.

**Solution:**
```dart
await for (final page in _streamChatPages()) {
  // Process metadata first
  await _saveChatMetadata(page);
  // Fetch icons in parallel
  await Future.wait(
    page.where((c) => c.isGroup).map((c) => Chat.getIcon(c, force: false))
  );
}
```

**Acceptance Criteria:**
- [ ] Group icon fetches do not serialize page processing
- [ ] All icons for page fetched concurrently
