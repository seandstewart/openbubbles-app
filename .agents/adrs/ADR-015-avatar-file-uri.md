# ADR-015 — Pass Notification Avatars by File Path Instead of Byte Array

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M4-memory.md)

## Context

When creating incoming message notifications, Dart encodes chat avatar as PNG bytes, passes via `MethodChannel.invokeMethod()` as `Uint8List`, becomes `ByteArray` in Kotlin, decoded to `Bitmap`.

Avatar data exists simultaneously in three memory locations:
1. Dart heap (`Uint8List`)
2. JNI transfer buffer (native memory)
3. Kotlin heap (`ByteArray` then `Bitmap`)

256×256 avatar: ~200 KB PNG encoded, ~262 KB decoded Bitmap. Triple-copy on every incoming notification.

## Decision

Write avatar PNG files to app cache dir keyed by chat GUID. Pass file path string through `invokeMethod`. Kotlin loads Bitmap directly from file.

**Dart side:**
```dart
Future<String> _getAvatarFilePath(Chat chat) async {
  final dir = Directory('${(await getApplicationCacheDirectory()).path}/avatars');
  await dir.create(recursive: true);
  final file = File('${dir.path}/${chat.guid}.png');
  
  if (!await file.exists() || _avatarDirty(chat.guid)) {
    final bytes = await _renderAvatarBytes(chat);
    await file.writeAsBytes(bytes);
    _markAvatarClean(chat.guid);
  }
  return file.path;
}
```

**Kotlin side:**
```kotlin
val avatarPath = args["chatAvatarPath"] as? String
val icon = avatarPath?.let {
    BitmapFactory.decodeFile(it)?.let { bmp ->
        IconCompat.createWithBitmap(bmp)
    }
}
```

Avatar files invalidated and rewritten when chat avatar changes (group photo update, contact photo change).

## Consequences

**Positive:**
- Avatar bytes exist in only one location at a time (file)
- MethodChannel payload drops from ~200 KB to ~100 bytes (path string)
- Avatar file reused across multiple notifications for same chat

**Negative:**
- First notification for chat with new avatar requires disk write before posting
- Stale avatar files accumulate if not cleaned up — need cleanup on app startup or avatar change

## Alternatives Considered

**A: Use `ContentProvider` with `FileProvider` URI**  
More Android-idiomatic for cross-process file sharing, but adds complexity. File path simpler — same process.

**B: Cache Bitmap in Kotlin layer**  
Requires Kotlin-side cache invalidation when Dart updates avatar. File-based caching lets Dart own source of truth.
