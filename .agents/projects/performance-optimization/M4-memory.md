# M4 — Memory Footprint

**Theme:** Prevent OOM crashes; stable RAM on media-heavy chats  
**Status:** Proposed  
**ADRs:** [ADR-008](../../adrs/ADR-008-lru-image-cache.md), [ADR-014](../../adrs/ADR-014-chunked-cloudkit-erase.md), [ADR-015](../../adrs/ADR-015-avatar-file-uri.md)

---

## Task 4.1 — Add LRU Eviction to `imageData` Cache

**Severity:** 🟠 High  
**Effort:** Low  
**ADR:** [ADR-008](../../adrs/ADR-008-lru-image-cache.md)

**Files:**
- `lib/services/ui/chat/` — `ConversationViewController`

**Problem:** `imageData: Map<String, Uint8List>` accumulates image bytes indefinitely. No eviction. Media-heavy conversations consume hundreds of MB.

**Solution:** Replace with fixed-capacity LRU cache using `LinkedHashMap` with access-order semantics:
```dart
static const _maxImages = 50;
final _imageCache = LinkedHashMap<String, Uint8List>();

Uint8List? getImage(String guid) {
  final val = _imageCache.remove(guid);
  if (val != null) _imageCache[guid] = val; // promote to MRU
  return val;
}

void cacheImage(String guid, Uint8List bytes) {
  _imageCache[guid] = bytes;
  while (_imageCache.length > _maxImages) {
    _imageCache.remove(_imageCache.keys.first); // evict LRU
  }
}
```

**Acceptance Criteria:**
- [ ] `imageData` never exceeds 50 entries (~100 MB worst-case)
- [ ] Evicted images re-loaded from disk on next access
- [ ] Long-running sessions do not grow heap unboundedly

---

## Task 4.2 — Fix `eraseCloudKitSync()` to Use Chunked Updates

**Severity:** 🔴 Critical  
**Effort:** Low  
**ADR:** [ADR-014](../../adrs/ADR-014-chunked-cloudkit-erase.md)

**Files:**
- `lib/services/rustpush/rustpush_service.dart` — `eraseCloudKitSync()`

**Problem:** `Database.messages.getAll()`, `Database.chats.getAll()`, `Database.attachments.getAll()` called simultaneously. OOM on devices with large message history.

**Solution:** Stream through each table in chunks of 500:
```dart
Future<void> _clearCkIds<T>(Box<T> box, void Function(T) clearId) async {
  const chunk = 500;
  final query = box.query().build();
  int offset = 0;
  while (true) {
    final items = query.findWithOffset(offset, limit: chunk);
    if (items.isEmpty) break;
    for (final item in items) clearId(item);
    box.putMany(items);
    offset += chunk;
  }
  query.close();
}
```

**Acceptance Criteria:**
- [ ] `eraseCloudKitSync()` holds at most 500 entities in memory at once
- [ ] Completes successfully on device with 50,000 messages
- [ ] No OOM crash during operation

---

## Task 4.3 — Bound `MethodCallHandler.queuedMessages`

**Severity:** 🟠 High  
**Effort:** Low  

**Files:**
- `android/app/src/main/kotlin/com/bluebubbles/messaging/services/backend_ui_interop/MethodCallHandler.kt`

**Problem:** `queuedMessages: HashMap<Int, String>` has no size cap or TTL — leaks indefinitely if messages arrive faster than workers process them.

**Solution:**
```kotlin
private const val MAX_QUEUED = 200
private const val MAX_AGE_MS = 5 * 60 * 1000L

data class QueuedMsg(val payload: String, val ts: Long = System.currentTimeMillis())

val queuedMessages = object : LinkedHashMap<Int, QueuedMsg>() {
    override fun removeEldestEntry(e: MutableMap.MutableEntry<Int, QueuedMsg>) =
        size > MAX_QUEUED || System.currentTimeMillis() - e.value.ts > MAX_AGE_MS
}
```

**Acceptance Criteria:**
- [ ] Queue never exceeds 200 entries
- [ ] Entries older than 5 minutes auto-evicted

---

## Task 4.4 — Pass Notification Avatars by File URI, Not Byte Array

**Severity:** 🟠 High  
**Effort:** Medium  
**ADR:** [ADR-015](../../adrs/ADR-015-avatar-file-uri.md)

**Files:**
- `lib/services/backend/notifications/` — `NotificationsService`
- `android/app/src/main/kotlin/com/bluebubbles/messaging/services/notifications/CreateIncomingMessageNotification.kt`

**Problem:** Avatar PNG bytes exist simultaneously in Dart heap, JNI transfer buffer, and Kotlin heap — every notification triples avatar memory footprint.

**Solution:**
1. Dart writes avatar bytes to `<cacheDir>/avatars/<chatGuid>.png` on first use; skips write if file exists and avatar unchanged.
2. Pass file path string through `invokeMethod` instead of bytes.
3. Kotlin loads `Bitmap` directly: `BitmapFactory.decodeFile(path)`.

**Acceptance Criteria:**
- [ ] Avatar bytes never duplicated across Dart and Kotlin heaps
- [ ] Avatar file written once, reused across notifications for same chat
- [ ] Stale avatar files cleaned up when chat's avatar changes
