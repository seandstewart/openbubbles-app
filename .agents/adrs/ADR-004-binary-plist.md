# ADR-004 — Replace XML Plist with Binary Plist for State Persistence

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M1-startup.md)

## Context

All on-disk state in Rust layer (identity, users, APS keys, hardware config, GSA credentials) persisted as XML plist via `plist_to_string()` / `plist::to_file_xml()`. XML plist is:
- **Verbose:** 10-field struct → ~800 bytes XML vs ~200 bytes binary
- **Slow:** XML parsing significantly slower than binary plist parsing
- **Fragile:** UTF-8 edge cases cause `String::from_utf8(val).unwrap()` panic in `plist_to_string`

`plist` Rust crate supports binary plist natively via `plist::to_writer_binary`. Read path (`plist::from_file`) auto-detects format, so binary-written files read without code change.

## Decision

Switch all plist write sites in `api.rs` and `native.rs` to binary format:

```rust
// Before:
plist::to_file_xml(&path, &value)?;

// After:
let mut file = tokio::fs::File::create(&path).await?;
plist::to_writer_binary(&mut file, &value)?;
```

For string-serialization paths (`plist_to_string`), switch to `plist::to_format_binary` or pass bytes directly.

**Migration:** Add one-time migration step in `migrate()` that:
1. Checks if existing state files are XML format (starts with `<?xml`)
2. Re-reads with `plist::from_file` (works for both formats)
3. Re-writes as binary with `plist::to_writer_binary`

## Consequences

**Positive:**
- State file sizes reduced 60–70%
- Serialization/deserialization 5–10x faster
- Eliminates `String::from_utf8(...).unwrap()` panic risk in `plist_to_string`

**Negative:**
- Binary plist not human-readable (harder to debug state issues manually)
- Migration step adds complexity to `migrate()`, slightly increases first-launch time

## Alternatives Considered

**A: Switch to CBOR or MessagePack via `serde`**  
Requires new crate dep. Binary plist already supported by existing `plist` crate; maintains compatibility with Apple tooling for debugging.

**B: Keep XML, remove `.unwrap()` panics**  
Fixes stability but not performance. Verbosity and parsing cost remain.
