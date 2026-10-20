//! At-rest encryption for the device-pool file (`device_pool.json`).
//!
//! The pool holds per-device `secret_key`s. They used to be written as
//! plaintext JSON. With a key provisioned (Dart hands one over via the
//! `set_device_pool_key` FRB call at startup, backed by the same secure
//! storage infrastructure as the Hive key but separate key material), the
//! file is instead:
//!
//! ```text
//! "FQPOOL1" || iv[16] || hmac[32] || AES-256-CBC(pkcs7(json))
//! ```
//!
//! Scheme choice: AES-CBC + HMAC-SHA256 rather than AES-GCM, because the
//! crate already depends on `aes`, `cbc`, and `sha2` — no new dependency
//! (and no Cargo.lock churn) for an equivalent authenticated-encryption
//! construction. Keys are separated by domain: `enc_key =
//! SHA256("fqapp-pool-enc" || key)`, `mac_key = SHA256("fqapp-pool-mac" ||
//! key)`, HMAC covers `magic || iv || ciphertext`.
//!
//! Backward compatibility: with no key provisioned, the pool keeps the old
//! plaintext JSON behavior and logs a warning on every save (once per
//! process). A plaintext file found after a key is provisioned loads
//! normally and is encrypted on the next save (migration on save).
//!
//! An encrypted file that cannot be decrypted loads as empty - the pool
//! refills by re-registering. With a key available but the wrong one (or a
//! tampered file) it is moved aside to `<file>.corrupt-<unix-seconds>` as it
//! loads. With no key provisioned it is instead left in place, so a later
//! session that does have the key can still decrypt it; the destructive case
//! is the next plaintext save, and that is where the move-aside happens (see
//! `DevicePool::save`). An encrypted pool is therefore never silently
//! overwritten with plaintext.

use std::sync::RwLock;

use rand::Rng;
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

/// Magic prefix of an encrypted pool file.
pub const POOL_MAGIC: &[u8; 7] = b"FQPOOL1";

const IV_LEN: usize = 16;
const HMAC_LEN: usize = 32;

/// The provisioned pool key (32 bytes), or `None` when Dart has not handed
/// one over yet. Held in a `Zeroizing` wrapper; a process exit leaks it
/// like any other static, which is the accepted lifetime for a session key.
static POOL_KEY: RwLock<Option<Zeroizing<[u8; 32]>>> = RwLock::new(None);

/// Provision the pool key. Called once from Dart at startup via
/// `set_device_pool_key`; a later call replaces the key (e.g. after the
/// secure-storage entry was regenerated). A wrong-length key is an error,
/// never a truncation.
pub fn provision_pool_key(key: Vec<u8>) -> Result<(), String> {
    if key.len() != 32 {
        return Err(format!(
            "device pool key must be 32 bytes, got {}",
            key.len()
        ));
    }
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&key);
    let mut key = key;
    crate::crypto::wipe(&mut key);
    match POOL_KEY.write() {
        Ok(mut slot) => {
            *slot = Some(Zeroizing::new(arr));
            Ok(())
        }
        Err(_) => Err("device pool key lock poisoned".to_string()),
    }
}

/// A copy of the provisioned key, or `None` when no key is provisioned.
pub fn pool_key() -> Option<[u8; 32]> {
    POOL_KEY
        .read()
        .ok()
        .and_then(|slot| slot.as_ref().map(|k| **k))
}

/// True when `data` is an encrypted pool file (magic prefix).
pub fn pool_file_is_encrypted(data: &[u8]) -> bool {
    data.starts_with(POOL_MAGIC)
}

fn derive_key(domain: &str, key: &[u8; 32]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(domain.as_bytes());
    hasher.update(key);
    let out = hasher.finalize();
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&out);
    arr
}

fn hmac_sha256(key: &[u8; 32], msg: &[u8]) -> [u8; 32] {
    // HMAC-SHA256 with a 64-byte block size; the key is already 32 bytes.
    const BLOCK: usize = 64;
    let mut k_ipad = [0x36u8; BLOCK];
    let mut k_opad = [0x5cu8; BLOCK];
    for i in 0..32 {
        k_ipad[i] ^= key[i];
        k_opad[i] ^= key[i];
    }
    let mut inner = Sha256::new();
    inner.update(k_ipad);
    inner.update(msg);
    let inner_hash = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(k_opad);
    outer.update(inner_hash);
    let out = outer.finalize();
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&out);
    arr
}

/// Constant-time equality for authentication tags.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    // `diff == 0` computed without a data-dependent branch.
    (diff as u16) == 0
}

/// Encrypts pool JSON with the provisioned key.
pub fn encrypt_pool_file(plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let mut key = pool_key().ok_or_else(|| "no device pool key provisioned".to_string())?;
    let enc_key = derive_key("fqapp-pool-enc", &key);
    let mac_key = derive_key("fqapp-pool-mac", &key);
    crate::crypto::wipe(&mut key);
    let iv: [u8; IV_LEN] = rand::thread_rng().gen();
    let padded = crate::crypto::pkcs7_pad(plaintext, crate::crypto::BLOCK);
    let ct = crate::crypto::aes_cbc_encrypt(&padded, &enc_key, &iv);
    let mut out = Vec::with_capacity(POOL_MAGIC.len() + IV_LEN + HMAC_LEN + ct.len());
    out.extend_from_slice(POOL_MAGIC);
    out.extend_from_slice(&iv);
    // HMAC covers magic || iv || ciphertext.
    let mut mac_input = Vec::with_capacity(POOL_MAGIC.len() + IV_LEN + ct.len());
    mac_input.extend_from_slice(POOL_MAGIC);
    mac_input.extend_from_slice(&iv);
    mac_input.extend_from_slice(&ct);
    let tag = hmac_sha256(&mac_key, &mac_input);
    out.extend_from_slice(&tag);
    out.extend_from_slice(&ct);
    Ok(out)
}

/// Decrypts an encrypted pool file. Any tampering, truncation, wrong key,
/// or non-encrypted input is an error.
pub fn decrypt_pool_file(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut key = pool_key().ok_or_else(|| "no device pool key provisioned".to_string())?;
    if !pool_file_is_encrypted(data) {
        return Err("not an encrypted pool file".to_string());
    }
    let min_len = POOL_MAGIC.len() + IV_LEN + HMAC_LEN;
    if data.len() < min_len {
        return Err(format!(
            "encrypted pool file truncated: {} < {min_len}",
            data.len()
        ));
    }
    let enc_key = derive_key("fqapp-pool-enc", &key);
    let mac_key = derive_key("fqapp-pool-mac", &key);
    crate::crypto::wipe(&mut key);
    let iv = &data[POOL_MAGIC.len()..POOL_MAGIC.len() + IV_LEN];
    let tag = &data[POOL_MAGIC.len() + IV_LEN..POOL_MAGIC.len() + IV_LEN + HMAC_LEN];
    let ct = &data[POOL_MAGIC.len() + IV_LEN + HMAC_LEN..];
    // The tag sits between iv and ciphertext, so the MAC input is not a
    // contiguous slice of the file: rebuild magic || iv || ciphertext.
    let mut mac_input = Vec::with_capacity(POOL_MAGIC.len() + IV_LEN + ct.len());
    mac_input.extend_from_slice(POOL_MAGIC);
    mac_input.extend_from_slice(iv);
    mac_input.extend_from_slice(ct);
    let expected = hmac_sha256(&mac_key, &mac_input);
    if !ct_eq(tag, &expected) {
        return Err("encrypted pool file authentication failed".to_string());
    }
    let pt = crate::crypto::aes_cbc_decrypt(ct, &enc_key, iv);
    Ok(crate::crypto::pkcs7_unpad_strict(&pt, crate::crypto::BLOCK)?.to_vec())
}

#[cfg(test)]
mod pool_crypto_tests {
    use super::*;

    fn key_a() -> [u8; 32] {
        [0x11; 32]
    }

    fn key_b() -> [u8; 32] {
        [0x22; 32]
    }

    /// Encrypt/decrypt with an explicit key, without touching the global.
    fn round_trip(key: &[u8; 32], plain: &[u8]) -> Vec<u8> {
        let enc_key = derive_key("fqapp-pool-enc", key);
        let mac_key = derive_key("fqapp-pool-mac", key);
        let iv: [u8; IV_LEN] = [0x33; IV_LEN];
        let padded = crate::crypto::pkcs7_pad(plain, crate::crypto::BLOCK);
        let ct = crate::crypto::aes_cbc_encrypt(&padded, &enc_key, &iv);
        let mut out = Vec::new();
        out.extend_from_slice(POOL_MAGIC);
        out.extend_from_slice(&iv);
        let mut mac_input = Vec::new();
        mac_input.extend_from_slice(POOL_MAGIC);
        mac_input.extend_from_slice(&iv);
        mac_input.extend_from_slice(&ct);
        out.extend_from_slice(&hmac_sha256(&mac_key, &mac_input));
        out.extend_from_slice(&ct);
        out
    }

    fn decrypt_with(key: &[u8; 32], data: &[u8]) -> Result<Vec<u8>, String> {
        if !pool_file_is_encrypted(data) {
            return Err("not an encrypted pool file".to_string());
        }
        // Mirror the production length guard: a truncated file is an
        // error, not a slice panic.
        if data.len() < POOL_MAGIC.len() + IV_LEN + HMAC_LEN {
            return Err("encrypted pool file truncated".to_string());
        }
        let iv = &data[POOL_MAGIC.len()..POOL_MAGIC.len() + IV_LEN];
        let tag = &data[POOL_MAGIC.len() + IV_LEN..POOL_MAGIC.len() + IV_LEN + HMAC_LEN];
        let ct = &data[POOL_MAGIC.len() + IV_LEN + HMAC_LEN..];
        let enc_key = derive_key("fqapp-pool-enc", key);
        let mac_key = derive_key("fqapp-pool-mac", key);
        let mut mac_input = Vec::new();
        mac_input.extend_from_slice(POOL_MAGIC);
        mac_input.extend_from_slice(iv);
        mac_input.extend_from_slice(ct);
        let expected = hmac_sha256(&mac_key, &mac_input);
        if !ct_eq(tag, &expected) {
            return Err("authentication failed".to_string());
        }
        let pt = crate::crypto::aes_cbc_decrypt(ct, &enc_key, iv);
        Ok(crate::crypto::pkcs7_unpad_strict(&pt, crate::crypto::BLOCK)?.to_vec())
    }

    #[test]
    fn encrypt_decrypt_round_trip() {
        let plain = br#"{"android":[],"last_update":"2026-01-01 00:00:00"}"#;
        let blob = round_trip(&key_a(), plain);
        assert!(pool_file_is_encrypted(&blob));
        assert_eq!(decrypt_with(&key_a(), &blob).unwrap(), plain);
    }

    #[test]
    fn wrong_key_and_tampering_fail() {
        let plain = b"pool json";
        let blob = round_trip(&key_a(), plain);
        assert!(decrypt_with(&key_b(), &blob).is_err());

        let mut tampered = blob.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 0x01;
        assert!(decrypt_with(&key_a(), &tampered).is_err());

        let mut truncated = blob.clone();
        truncated.truncate(10);
        assert!(decrypt_with(&key_a(), &truncated).is_err());

        assert!(decrypt_with(&key_a(), b"plain json").is_err());
    }
}
