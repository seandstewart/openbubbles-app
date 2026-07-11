# ADR-018 — Replace Hardcoded Desktop AES Key with Platform Keychain Integration

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M7-hardening.md)

## Context

On desktop (macOS, Linux, Windows), `SharedPushState::restore()` uses `SoftwareEncryptor` with hardcoded 32-byte AES-GCM key:

```rust
// rust/src/api/api.rs
encryptor: SoftwareEncryptor(*b"desktopisinsecureyoushouldn'tber"),
```

Key baked into compiled binary. Attacker with filesystem access can:
1. Read encrypted state files (identity, credentials, APS keys)
2. Decrypt using hardcoded key extracted from binary
3. Impersonate user's Apple ID

Affects `gsa.plist` containing hashed Apple ID password. Though hashed, blob protected only by known static key — far weaker than hardware-backed keystore.

## Decision

Replace hardcoded key with per-installation randomly generated key stored in platform secret storage:

**macOS:** Use macOS Keychain via `security-framework` crate:
```rust
use security_framework::passwords::{get_generic_password, set_generic_password};

fn get_or_create_key() -> Result<[u8; 32]> {
    match get_generic_password("com.openbubbles", "encryption_key") {
        Ok(pw) => Ok(pw.try_into()?),
        Err(_) => {
            let key: [u8; 32] = rand::random();
            set_generic_password("com.openbubbles", "encryption_key", &key)?;
            Ok(key)
        }
    }
}
```

**Linux:** Use `libsecret` via `secret-service` crate (GNOME Keyring / KWallet).

**Windows:** Use DPAPI via `windows::Security::Cryptography::DataProtection`.

**Fallback (no secret store available):** Generate random 32-byte key, store at `<data_dir>/key.bin` with `0600` permissions. Better than hardcoded (unique per installation) but not hardware-backed.

**Migration:** On first launch after change:
1. Check if `key.bin` or Keychain entry exists
2. If neither: generate new key, store it
3. Re-encrypt all existing state files (identity.plist, users.plist, etc.) with new key

## Consequences

**Positive:**
- Desktop installs use per-installation random keys — compromising one device doesn't compromise another
- On macOS and Linux, keys stored in OS keychain with ACL protection
- Hardcoded key string removed from binary

**Negative:**
- Users moving app data to different machine must re-authenticate (key is machine-specific)
- Migration re-encrypts all state files on first launch — adds ~1s to first launch after upgrade
- Keychain integration adds platform-specific crate dependencies

## Alternatives Considered

**A: Keep hardcoded key, obfuscate in binary**  
Security through obscurity — doesn't address threat model. Binary analysis trivially recovers key.

**B: Derive key from device hardware identifier**  
Device serial/IMEI not reliably accessible on desktop without elevated permissions. Not portable.

**C: Skip encryption on desktop, rely on filesystem permissions**  
State files contain hashed Apple ID password and APS private keys. Deserve encryption-at-rest even with filesystem ACLs.
