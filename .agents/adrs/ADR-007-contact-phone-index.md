# ADR-007 — Contact Phone Number and Email Index

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M3-ui-responsiveness.md)

## Context

`ContactsService.matchHandleToContact(address)` performs full linear scan of all contacts for each handle lookup:

```dart
for (final contact in contacts) {
  for (final phone in contact.phones) {
    if (_normalize(phone.number) == _normalize(address)) return contact;
  }
}
```

With 5,000 contacts averaging 3 phones each, single lookup is O(15,000) string comparisons. Called:
- Once per handle during `HandleSyncManager` streaming (O(handles × contacts × phones))
- On every `matchHandleToContact` call from `ChatLifecycleManager`
- During `refreshContacts()` for all existing handles

`HandleSyncManager` with 3,000 handles and 5,000 contacts performs ~45 million string comparisons per full sync.

## Decision

Build normalized-phone and email lookup indices in `ContactsService` immediately after loading or refreshing contacts:

```dart
final Map<String, Contact> _phoneIndex = {};
final Map<String, Contact> _emailIndex = {};

void _buildIndex() {
  _phoneIndex.clear();
  _emailIndex.clear();
  for (final contact in contacts) {
    for (final phone in contact.phones) {
      final key = _normalizePhone(phone.number);
      if (key.isNotEmpty) _phoneIndex[key] = contact;
    }
    for (final email in contact.emails) {
      _emailIndex[email.address.toLowerCase().trim()] = contact;
    }
  }
}
```

Existing normalization logic (`_normalize`) moved into `_normalizePhone`, applied at index-build time, not lookup time.

**Index rebuild triggers:**
- After `loadContacts()` completes
- After `refreshContacts()` completes
- Never during individual lookups

## Consequences

**Positive:**
- `matchHandleToContact` reduces from O(contacts × phones) to O(1)
- Handle sync time drops from minutes to seconds for large contact lists
- All handle-to-contact matching code paths benefit automatically

**Negative:**
- `_phoneIndex` holds up to ~15,000 entries (5,000 contacts × 3 phones) — ~1.5 MB at ~100 bytes/entry — acceptable
- Index must be rebuilt on contact refresh; rebuild is O(contacts × phones) but happens once, not per lookup

## Alternatives Considered

**A: Use ObjectBox's indexed `Handle.formattedAddress` field for lookup**  
Contacts loaded from device OS (not ObjectBox), so doesn't apply to contact-matching step. ObjectBox indexes help Handle storage, not OS contact lookup.

**B: Pre-compute contact matches when handles first stored**  
Done to some extent via `Handle.contactRelation`, but relation not always populated; lookup still happens on every sync.
