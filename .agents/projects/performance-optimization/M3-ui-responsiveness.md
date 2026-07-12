# M3 — UI Responsiveness

**Theme:** Smooth scrolling and rendering on mid-range devices  
**Status:** Proposed  
**ADRs:** [ADR-005](../../adrs/ADR-005-batch-message-watcher.md), [ADR-006](../../adrs/ADR-006-globalchatservice-delta.md), [ADR-007](../../adrs/ADR-007-contact-phone-index.md), [ADR-012](../../adrs/ADR-012-parallel-avatar-loading.md), [ADR-013](../../adrs/ADR-013-mlkit-off-build-path.md)

---

## Task 3.1 — Replace Per-Message ObjectBox Watchers with a Single Batch Watcher

**Severity:** 🔴 Critical  
**Effort:** High  
**ADR:** [ADR-005](../../adrs/ADR-005-batch-message-watcher.md)

**Files:**
- `lib/services/ui/message/` — `MessageWidgetController.onInit()`
- `lib/services/ui/message/` — `MessagesService`

**Problem:** Every rendered `MessageHolder` creates its own ObjectBox reactive query. 100 messages = 100 concurrent watchers, each firing async DB read
 on every write to `messages` box.

**Solution:**
1. Remove per-message `Database.messages.query(Message_.id.equals(id)).watch()` from `MessageWidgetController.onInit()`.
2. Promote to single watcher in `MessagesService` scoped to conversation: `Database.messages.query(Message_.chat.id.equals(chatId)).watch()`.
3. On watcher fire, diff result set against cached version, emit changed message IDs.
4. `MessageWidgetController` subscribes to diff stream from `MessagesService`, keyed by message ID.

```dart
// MessagesService
late final StreamSubscription _messageWatcher;
final Map<int, Message> _messageCache = {};

void _initWatcher(int chatId) {
  _messageWatcher = Database.messages
      .query(Message_.chat.id.equals(chatId))
      .watch()
      .listen((query) {
    final updated = {for (final m in query.find()) m.id!: m};
    final changed = updated.entries
        .where((e) => _messageCache[e.key] != e.value)
        .map((e) => e.key)
        .toSet();
    _messageCache
      ..clear()
      ..addAll(updated);
    for (final id in changed) {
      _messageChangedController.add(id);
    }
  });
}
```

**Acceptance Criteria:**
- [ ] Opening 200-message conversation creates exactly 1 ObjectBox watcher
- [ ] Message updates reflect in UI within 100ms
- [ ] No regression in reaction/edit/unsend UI updates

---

## Task 3.2 — Scope `GlobalChatService` Watcher with Change Deltas

**Severity:** 🔴 Critical  
**Effort:** Medium  
**ADR:** [ADR-006](../../adrs/ADR-006-globalchatservice-delta.md)

**Files:**
- `lib/services/ui/chat/` — `GlobalChatService`

**Problem:** Any chat write triggers `Database.chats.getAll()` + two O(N) scans. Fires constantly during normal use.

**Solution:** Only reload and re-evaluate chats whose IDs appear in changed set:
```dart
Database.chats.query().watch().listen((event) {
  final all = event.find();
  // Build ID set of what actually changed vs cached
  final changedIds = all
      .where((c) => _chatCache[c.id] != c.unreadCount)
      .map((c) => c.id!)
      .toSet();
  for (final id in changedIds) {
    final chat = _chatCache[id] = all.firstWhere((c) => c.id == id);
    _updateUnread(chat);
    _updateMute(chat);
  }
});
```

**Acceptance Criteria:**
- [ ] Receiving message in one chat does not re-evaluate all other chats
- [ ] Unread count badge updates within 200ms of message receipt
- [ ] Memory profile shows no growing chat collection

---

## Task 3.3 — Build Contact Phone Number Index

**Severity:** 🟠 High  
**Effort:** Low  
**ADR:** [ADR-007](../../adrs/ADR-007-contact-phone-index.md)

**Files:**
- `lib/services/ui/contact_service.dart`

**Problem:** `matchHandleToContact()` does full linear scan of all contacts per handle lookup. 5,000 contacts × 3 phones × 500 handles = 7.5M iterations per full refresh.

**Solution:**
```dart
final Map<String, Contact> _phoneIndex = {};
final Map<String, Contact> _emailIndex = {};

void _buildIndex() {
  _phoneIndex.clear();
  _emailIndex.clear();
  for (final contact in contacts) {
    for (final phone in contact.phones) {
      _phoneIndex[_normalizePhone(phone.number)] = contact;
    }
    for (final email in contact.emails) {
      _emailIndex[email.address.toLowerCase()] = contact;
    }
  }
}

Contact? matchHandleToContact(String address) {
  if (address.contains('@')) {
    return _emailIndex[address.toLowerCase()];
  }
  return _phoneIndex[_normalizePhone(address)];
}
```
Rebuild `_buildIndex()` only when `contacts` refreshed.

**Acceptance Criteria:**
- [ ] `matchHandleToContact` executes in O(1)
- [ ] Handle sync time decreases proportionally
- [ ] Contact matching accuracy unchanged (same normalization logic)

---

## Task 3.4 — Parallelize Contact Avatar Loading

**Severity:** 🟠 High  
**Effort:** Low  
**ADR:** [ADR-012](../../adrs/ADR-012-parallel-avatar-loading.md)

**Files:**
- `lib/services/ui/contact_service.dart`

**Problem:** Avatars loaded one at a time via sequential `await` in `for` loop. 5,000 contacts × sequential I/O = minutes.

**Solution:**
```dart
const _avatarBatchSize = 20;
for (int i = 0; i < _contacts.length; i += _avatarBatchSize) {
  final batch = _contacts.sublist(i, min(i + _avatarBatchSize, _contacts.length));
  await Future.wait(batch.map((c) async {
    c.avatar = await getContactAvatar(c.id);
  }));
}
```

**Acceptance Criteria:**
- [ ] Contact avatar loading completes 10–20× faster
- [ ] No memory spike from loading all avatars simultaneously (batch cap enforces this)

---

## Task 3.5 — Pre-Warm ML Kit Extraction Off the Widget Build Path

**Severity:** 🟠 High  
**Effort:** Low  
**ADR:** [ADR-013](../../adrs/ADR-013-mlkit-off-build-path.md)

**Files:**
- `lib/app/layouts/conversation_view/` — message span builder
- `lib/services/ui/message/` — `MessageWidgetController`

**Problem:** First render of each message part triggers ML Kit entity extraction inline during widget build — causes jank.

**Solution:**
1. Move extraction to `MessageWidgetController.onInit()` as `compute()` call (or background isolate).
2. Store result in `ConversationViewController.mlKitParsedText` before widget builds.
3. Widget build path checks cache only — never calls extractor.

**Acceptance Criteria:**
- [ ] No ML Kit calls during `build()`
- [ ] First render of new messages does not drop frames
- [ ] Entity annotations available within 500ms of message receipt

---

## Task 3.6 — Replace `runAsync` with True Background Isolate Work

**Severity:** 🟡 Medium  
**Effort:** Medium  

**Files:**
- `lib/helpers/ui/async_task.dart`

**Problem:** `runAsync` uses `SchedulerBinding.scheduleTask(Priority.animation)` — still on UI isolate. DB reads deferred with it compete with frame rendering.

**Solution:** Replace with `compute()` for pure data transformation, `Store.attach()` pattern for ObjectBox reads from secondary isolate.

**Acceptance Criteria:**
- [ ] Heavy DB reads do not block frame rendering
- [ ] No regression in data freshness

---

## Task 3.7 — Use Insertion Sort for New Messages, Skip Sort for Typing Indicators

**Severity:** 🟡 Medium  
**Effort:** Low  

**Files:**
- `lib/services/ui/message/` — `MessagesService`

**Problem:** `_messages.sort(Message.sort)` is O(N log N), called on every event including typing indicators.

**Solution:**
1. On `handleNewMessage`: binary-search for insertion point, use `List.insert()` instead of sort.
2. On `handleUpdatedMessage`: only re-sort if message's sort key (date) changed.
3. On typing indicator events: do not modify or sort `_messages`.

**Acceptance Criteria:**
- [x] Sort never called for typing indicator events
- [x] New messages inserted in O(log N)

---

## Task 3.8 — Fix `MessageHolder` Event Bus Subscription Leak

**Severity:** 🟡 Medium  
**Effort:** Low  

**Files:**
- `lib/app/layouts/conversation_view/` — `_MessageHolderState`

**Problem:** Every `MessageHolder` subscribes to global event bus in `initState` without consistently cancelling in `dispose`.

**Solution:**
```dart
late final StreamSubscription<Tuple2<String, dynamic>> _eventSub;

@override
void initState() {
  super.initState();
  _eventSub = eventDispatcher.stream.listen((event) {
    if (event.item1 != 'refresh-avatar') return;
    // handle avatar refresh
  });
}

@override
void dispose() {
  _eventSub.cancel();
  super.dispose();
}
```

**Acceptance Criteria:**
- [x] No stream subscriptions survive past `dispose()`
- [x] Memory profiler shows stable subscription count during scroll

---

## Task 3.9 — Batch Chat Loading to Suppress Intermediate RxList Rebuilds

**Severity:** 🟡 Medium  
**Effort:** Low  

**Files:**
- `lib/services/ui/chat/` — `ChatsService.init()`

**Problem:** Each 15-chat batch fires `chats.value = newChats`, causing conversation list to fully rebuild after each batch (up to 14 rebuilds during startup).

**Solution:**
```dart
List<Chat> allChats = [];
for (int i = 0; i < batches; i++) {
  allChats.addAll(await Chat.getChats(limit: batchSize, offset: i * batchSize));
}
chats.value = allChats;      // single notification
loadedChatBatch.value = true;
```

**Acceptance Criteria:**
- [ ] `ChatsService.init()` triggers exactly 1 `RxList` notification
- [ ] Startup frame count decreases measurably (profiler)
