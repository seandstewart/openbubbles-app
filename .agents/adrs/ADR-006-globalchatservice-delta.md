# ADR-006 — GlobalChatService Delta-Based Updates

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M3-ui-responsiveness.md)

## Context

`GlobalChatService` maintains unread counts and mute states for all chats:

```dart
Database.chats.query().watch(triggerImmediately: true).listen((event) {
  final chats = event.find(); // loads ALL chats
  _evaluateUnreadInfo(chats); // O(N) scan
  _evaluateMuteInfo(chats);   // O(N) scan
});
```

Fires on every write to **any** chat. During normal use:
- Receiving message marks one chat unread → fires for all chats
- Read receipt → fires for all chats
- Background sync writing metadata → fires for all chats

With 200 chats, each event loads 200 entities and scans them twice. Fires constantly — multiple times per minute during active use.

## Decision

Maintain local `_chatCache: Map<int, Chat>` in `GlobalChatService`. On each watcher event, compare fresh results against cache to identify only changed entries, then update maps for just those:

```dart
final Map<int, Chat> _chatCache = {};

void _onChatUpdate(Query<Chat> query) {
  final fresh = query.find();
  final freshMap = {for (final c in fresh) c.id!: c};
  
  final changed = freshMap.entries
      .where((e) => _chatCache[e.key]?.unreadCount != e.value.unreadCount
                 || _chatCache[e.key]?.muteType != e.value.muteType)
      .map((e) => e.value)
      .toList();
  
  _chatCache
    ..clear()
    ..addAll(freshMap);
  
  for (final chat in changed) {
    _updateUnread(chat);
    _updateMute(chat);
  }
}
```

## Consequences

**Positive:**
- Processing cost per chat-write event is O(changed chats), not O(all chats)
- Common case (one chat updated) processes only 1 entity
- GetX reactive notifications only fire for affected chat's `RxBool`/`RxnString`

**Negative:**
- `_chatCache` holds full copy of all Chat objects — ~200 objects for typical users (negligible memory)
- Cache must be invalidated on full reload (app restart, full sync completion)

## Alternatives Considered

**A: Subscribe to per-chat watchers dynamically as chats are added**  
Requires managing dynamic watcher lifecycle (add on `addChat`, cancel on `removeChat`). More complex; risks watcher leaks.

**B: Use ObjectBox `query().watch()` with change set reporting**  
ObjectBox Dart API returns full result set, not delta. Diff must be computed in Dart.
