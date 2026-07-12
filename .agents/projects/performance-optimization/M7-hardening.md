# M7 — Hardening & Correctness

**Theme:** Crash prevention, security, and build reproducibility  
**Status:** Proposed  
**ADRs:** [ADR-018](../../adrs/ADR-018-desktop-key-security.md)

---

## Task 7.1 — Fix Operator Precedence Null Crash in Incremental Sync

**Severity:** 🟠 High  
**Effort:** Trivial  

**Files:**
- `lib/services/backend/sync/incremental_sync_manager.dart`

**Problem:**
```dart
// BUG: && binds tighter than ||; second clause executes when dateCreated is null
if (msg.dateCreated != null && lastSyncedTimestamp == null ||
    msg.dateCreated!.millisecondsSinceEpoch > lastSyncedTimestamp!)
```

**Solution:**
```dart
if (msg.dateCreated != null &&
    (lastSyncedTimestamp == null ||
     msg.dateCreated!.millisecondsSinceEpoch > lastSyncedTimestamp!))
```

**Acceptance Criteria:**
- [x] No null dereference in incremental sync timestamp tracking
- [x] Unit test added covering null `dateCreated` + non-null `lastSyncedTimestamp`

---

## Task 7.2 — Fix `ChatSyncManager` Exception Type Name

**Severity:** 🟡 Low  
**Effort:** Trivial  

**Files:**
- `lib/services/backend/sync/chat_sync_manager.dart`

**Problem:** `ChatRequestException.toString()` returns `"HandleRequestException"` — copy-paste error.

**Solution:** Change string to `"ChatRequestException"`.

**Acceptance Criteria:**
- [ ] Exception logs correctly identify `ChatSyncManager` errors

---

## Task 7.3 — Replace `.unwrap()` on File I/O with Proper Error Handling

**Severity:** 🟠 High  
**Effort:** Low  

**Files:**
- `rust/src/api/api.rs` — all `.unwrap()` / `.expect()` on file I/O

**Problem:** Disk-full or permissions error panics Tokio worker thread, terminating all async processing.

**Solution:**
1. Replace all `.unwrap()` on I/O with `?` propagation.
2. In `native.rs` `catch_unwind`: log and continue rather than re-panic.
3. Preserve original panic message:
```rust
.unwrap_or_else(|e| {
    let msg = e.downcast_ref::<&str>().copied()
        .or_else(|| e.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("unknown panic");
    log::error!("recv_wait panicked: {msg}");
})
```

**Acceptance Criteria:**
- [ ] No `.unwrap()` on file I/O in `api.rs`
- [ ] Disk-full condition logged, not panicked
- [ ] `catch_unwind` logs original panic message

---

## Task 7.4 — Pin `uniffi` Dependency to a Specific Revision

**Severity:** 🟡 Medium  
**Effort:** Trivial  

**Files:**
- `rust/Cargo.toml`

**Problem:** `uniffi` pulled from unpinned git HEAD makes builds non-reproducible.

**Solution:**
```toml
# Pin to a tested and verified commit SHA
uniffi = { git = "https://github.com/mozilla/uniffi-rs", rev = "<sha>" }
```

**Acceptance Criteria:**
- [ ] `cargo build` produces identical output across machines
- [ ] CI does not break on unexpected upstream changes

---

## Task 7.5 — Remove `println!` Debug Calls from Production Paths

**Severity:** 🟡 Low  
**Effort:** Trivial  

**Files:**
- `rust/src/api/api.rs` — lines 458, 1891
- `rust/src/lib.rs` — line 37

**Problem:** `println!()` flushes to stdout synchronously on every invocation, adding latency inside `update_keys` callback and attachment download loop.

**Solution:** Replace with `log::debug!()` (no-op in release builds at INFO level).

**Acceptance Criteria:**
- [ ] No `println!` calls in `api.rs` or `lib.rs`
- [ ] Release builds produce no stdout output in hot paths

---

## Task 7.6 — Replace Hardcoded Desktop AES Key with Platform Keychain

**Severity:** 🔴 Critical (security)  
**Effort:** Medium  
**ADR:** [ADR-018](../../adrs/ADR-018-desktop-key-security.md)

**Files:**
- `rust/src/api/api.rs` — `SoftwareEncryptor` initialization
- `rust/src/keystore.rs`

**Problem:** `SoftwareEncryptor(*b"desktopisinsecureyoushouldn'tber")` — all desktop credentials unencrypted at rest.

**Solution:**
- **macOS:** Use macOS Keychain via `security-framework` crate
- **Linux:** Use `libsecret` via `secret-service` crate  
- **Windows:** Use DPAPI via `dpapi-winapi` crate
- **Fallback:** Generate random 32-byte key, store in `0600`-permission file in app data dir

On first launch after migration: re-encrypt all existing data with new key.

**Acceptance Criteria:**
- [ ] Desktop installations do not use hardcoded AES key
- [ ] macOS: key stored in Keychain, survives app reinstall (same user)
- [ ] Migration re-encrypts existing state files
- [ ] Hardcoded key string no longer appears in compiled binary
