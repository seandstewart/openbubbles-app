# ADR-012 — Parallel Contact Avatar Loading

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M3-ui-responsiveness.md)

## Context

`ContactsService` loads contact avatars sequentially:

```dart
for (Contact c in _contacts) {
  c.avatar = await getContactAvatar(c.id);
}
```

`getContactAvatar` calls `FastContacts.getContactImage(id)` — async platform channel call to Android Contacts content provider. Each call takes 5–50ms depending on image size and device speed.

5,000 contacts × ~15ms avg = ~75s sequential I/O. Blocks `refreshContacts()` for over a minute on first load, delaying contact names/avatars across app.

## Decision

Load avatars in parallel batches of 20:

```dart
const _batchSize = 20;

Future<void> _loadAvatars(List<Contact> contacts) async {
  for (int i = 0; i < contacts.length; i += _batchSize) {
    final batch = contacts.sublist(i, min(i + _batchSize, contacts.length));
    await Future.wait(batch.map((c) async {
      try {
        c.avatar = await getContactAvatar(c.id);
      } catch (e) {
        // non-critical — contact shown without avatar
      }
    }));
  }
}
```

Batch size of 20 bounds concurrent platform channel calls to avoid overwhelming Android content provider and causing ANR-like behavior.

## Consequences

**Positive:**
- Avatar load time reduced from ~75s to ~4s (75s / 20x parallelism) for 5,000 contacts
- `refreshContacts()` completes much faster, unblocking contact info display

**Negative:**
- 20 concurrent calls to Android Contacts content provider — may cause ContentResolver contention on very old devices; batch size tunable if issues arise
- Error in one avatar load doesn't fail others (try/catch per contact)

## Alternatives Considered

**A: Load all avatars simultaneously with `Future.wait`**  
Risk of overwhelming content provider and OOM from 5,000 concurrent image decodings. Batching safer.

**B: Load avatars lazily as contacts appear on screen**  
Better for memory but requires complex lazy-loading infrastructure throughout contact display widgets. Too large a refactor for this milestone.
