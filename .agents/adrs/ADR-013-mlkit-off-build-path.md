# ADR-013 — Pre-Compute ML Kit Annotations Off the Widget Build Path

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M3-ui-responsiveness.md)

## Context

ML Kit entity extraction is triggered inline during widget `build()`:

```dart
// Inside buildEnrichedMessageSpans() called from build()
if (!controller.mlKitParsedText.containsKey(key)) {
  controller.mlKitParsedText[key] = await EntityExtractor(...).annotateText(text);
}
```

`await` inside build helper causes first render to schedule rebuild after annotation completes. While result is cached on subsequent builds, initial render of each new message part:
1. Renders without annotations (blank spans)
2. Starts ML Kit inference in background
3. Triggers rebuild on completion — visible jank

ML Kit inference takes 30–200ms per message. 25 messages loading → 25 sequential rebuilds.

## Decision

Move entity extraction to `MessageWidgetController.onInit()`, run via `compute()` (Dart isolate) — no UI thread blocking:

```dart
// In MessageWidgetController.onInit():
if (message.text != null && ss.settings.smartReply.value) {
  _extractAnnotations();
}

Future<void> _extractAnnotations() async {
  for (final part in message.attributedBody?.runs ?? []) {
    if (part.text == null) continue;
    final key = '${message.guid}-${part.offset}';
    if (cvc.mlKitParsedText.containsKey(key)) continue;
    
    final annotations = await compute(_runEntityExtraction, part.text!);
    cvc.mlKitParsedText[key] = annotations;
    updateWidgets<TextBubble>(null); // trigger rebuild only after annotation ready
  }
}

// Top-level function for compute():
List<EntityAnnotation> _runEntityExtraction(String text) {
  return EntityExtractor(EntityExtractorLanguage.english).annotateText(text);
}
```

Widget build path checks cache only:
```dart
final annotations = controller.mlKitParsedText['$guid-$offset'] ?? [];
```

## Consequences

**Positive:**
- Widget builds purely synchronous — no async awaits in build tree
- First render shows text immediately; annotations appear via `updateWidgets<TextBubble>` when ready
- ML Kit inference runs on separate isolate, not competing with UI rendering

**Negative:**
- Annotations appear slightly after initial render (visible only on first load of message)
- `compute()` has per-call overhead (~1ms isolate spawn) — acceptable given 30–200ms inference time

## Alternatives Considered

**A: Keep inline but use `FutureBuilder`**  
`FutureBuilder` in build tree introduces conditional rendering that complicates layout. `updateWidgets` pattern already established and more surgical.

**B: Pre-annotate on message receipt (before storing to DB)**  
Too early — message may not be displayed, wasting compute. Controller `onInit()` is right point (only runs when widget actually rendered).
