# ADR-005 — Replace Per-Message ObjectBox Watchers with a Single Conversation Watcher

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M3-ui-responsiveness.md)

## Context

`MessageWidgetController.onInit()` creates an ObjectBox reactive query for each rendered message:

```dart
final messageQuery = Database.messages
    .query(Message_.id.equals(message.id!))
    .watch();
sub = messageQuery.listen(...);
```

Conversation displaying 100 messages creates 100 concurrent ObjectBox watchers. ObjectBox evaluates all registered watchers on every `messages` box write. Each watcher then dispatches an async DB read. Practical effect:

- Every incoming message write triggers 100 concurrent DB reads
- Every reaction, edit, or read receipt triggers 100 concurrent DB reads
- Opening conversation with 200 messages immediately creates 200 subscriptions

Primary cause of UI sluggishness during active conversations. Catastrophic on low-RAM devices — GC pressure from 200 concurrent async ops causes frame drops.

## Decision

Remove per-message watcher from `MessageWidgetController`. Promote to single conversation-scoped watcher in `MessagesService`:

```dart
// MessagesService
void _initWatcher(int chatId) {
  _watcher = Database.messages
      .query(Message_.chat.id.equals(chatId))
      .watch()
      .listen((query) {
    final results = query.find();
    _diffAndNotify(results);
  });
}

void _diffAndNotify(List<Message> updated) {
  final updatedMap = {for (final m in updated) m.id!: m};
  for (final entry in updatedMap.entries) {
    final cached = _cache[entry.key];
    if (cached != entry.value) {
      _messageChangedStream.add(entry.key);
    }
  }
  _cache
    ..clear()
    ..addAll(updatedMap);
}
```

`MessageWidgetController` subscribes to `MessagesService._messageChangedStream` filtered by its message ID:

```dart
_sub = ms(chat.guid).messageChangedStream
    .where((id) => id == message.id)
    .listen((_) => _reloadMessage());
```

## Consequences

**Positive:**
- N messages in conversation = 1 ObjectBox watcher (not N)
- DB read load on message writes drops 99% for typical conversations
- Memory usage decreases proportionally
- Scroll performance on low-end devices improves significantly

**Negative:**
- `MessagesService` now holds full conversation message cache in memory — acceptable since `ConversationViewController` already caches more data
- Diff computation on each watcher fire is O(N messages loaded) — must be bounded by loaded message window
- Initial implementation complexity higher than current per-widget approach

## Alternatives Considered

**A: Keep per-message watchers, debounce them**  
Doesn't reduce watcher count. ObjectBox still evaluates all 100 watchers on every write; debouncing only delays DB reads.

**B: Single `getAll()` query with polling timer instead of reactive watcher**  
Introduces latency, wasteful when no messages change. Reactive is correct; problem is granularity.

**C: Switch from ObjectBox to SQLite with manual change notifications**  
Much larger migration. ObjectBox already embedded and performant; fixing query granularity is sufficient.
