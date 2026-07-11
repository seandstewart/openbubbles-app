# ADR-008 — LRU Eviction for In-Memory Image Cache

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M4-memory.md)

## Context

`ConversationViewController` maintains several unbounded in-memory maps:

```dart
final Map<String, Uint8List> imageData = {};       // decoded image bytes
final Map<String, ui.Image> images = {};           // rendered ui.Image objects  
final Map<String, Metadata> legacyUrlPreviews = {};
final Map<String, List<EntityAnnotation>> mlKitParsedText = {};
```

Maps grow monotonically for lifetime of conversation view. No eviction policy. Media-heavy conversation with 500 images at ~2 MB each — `imageData` alone can reach 1 GB, far exceeding memory on low-end Android (2–3 GB total, ~1 GB app-available).

`imageCacheQueue` processes images serially to avoid peak memory spikes, but accumulated `imageData` retains all previously processed images indefinitely.

## Decision

Replace `imageData` and `images` with fixed-capacity LRU caches using `LinkedHashMap` with insertion-order semantics and explicit eviction:

```dart
static const _maxCachedImages = 50;  // ~100 MB worst-case at 2 MB/image

final _imageData = LinkedHashMap<String, Uint8List>();

Uint8List? getImageData(String guid) {
  final val = _imageData.remove(guid);
  if (val != null) _imageData[guid] = val; // move to MRU position
  return val;
}

void setImageData(String guid, Uint8List bytes) {
  _imageData.remove(guid); // remove if present (reset position)
  _imageData[guid] = bytes;
  while (_imageData.length > _maxCachedImages) {
    _imageData.remove(_imageData.keys.first); // evict LRU
  }
}
```

Apply same pattern to `images: Map<String, ui.Image>` with cap of 30 entries (rendered images are larger).

`mlKitParsedText` bounded by unique message GUIDs visible at once — leave as-is, clear on `dispose()`.

`legacyUrlPreviews` bounded by unique URLs in conversation — leave as-is (typically small).

## Consequences

**Positive:**
- `imageData` memory capped at ~100 MB regardless of conversation history length
- Evicted images re-decoded from disk on next access (lazy reload)
- OOM crashes in media-heavy conversations eliminated

**Negative:**
- Scrolling back through media-heavy conversation re-loads images from disk — slight latency on cache misses
- Cap of 50 images is heuristic; power users may notice re-loading

## Alternatives Considered

**A: Use Flutter's `ImageCache` (`PaintingBinding.imageCache`)**  
Flutter's global image cache has size limit but keyed by `ImageProvider`, not attachment GUID. Integrating requires wrapping all attachment images as `ImageProvider` subclasses — larger refactor.

**B: Store images on disk only, never in memory**  
Attachments already downloaded to disk. In-memory cache exists to avoid repeated disk I/O during scrolling. Eliminating it would make scrolling slow. LRU is right tradeoff.

**C: Evict based on bytes rather than count**  
More accurate but requires tracking byte sizes. Count-based eviction simpler; 50-image cap provides reasonable upper bound.
