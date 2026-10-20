//! Shared block-cipher helpers.
//!
//! The Go implementation drives AES through `crypto/aes` + `crypto/cipher` in
//! CBC mode and always pads by hand (PKCS7 with an explicit block when the
//! input is already aligned). These helpers reproduce that exactly, for both
//! AES-128 (16-byte key) and AES-256 (32-byte key).

use aes::cipher::generic_array::GenericArray;
use aes::cipher::{BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use aes::{Aes128, Aes256};

type Enc128 = cbc::Encryptor<Aes128>;
type Dec128 = cbc::Decryptor<Aes128>;
type Enc256 = cbc::Encryptor<Aes256>;
type Dec256 = cbc::Decryptor<Aes256>;

pub const BLOCK: usize = 16;

/// Overwrites a buffer with zeros using volatile writes, so the compiler
/// cannot elide the wipe as a dead store. For key material that must not
/// linger in memory after use (see P2-6). Prefer `Zeroize`/`Zeroizing`
/// for owned buffers; this is for transient stack/array buffers.
pub(crate) fn wipe(buf: &mut [u8]) {
    for b in buf.iter_mut() {
        // SAFETY: write_volatile on a valid &mut reference is always sound.
        unsafe { std::ptr::write_volatile(b, 0) };
    }
}

/// Go's `pkcs7Pad`: pad is always in `1..=block` and equals `block` when the
/// input is already aligned.
pub fn pkcs7_pad(data: &[u8], block: usize) -> Vec<u8> {
    let pad = block - (data.len() % block);
    let mut out = Vec::with_capacity(data.len() + pad);
    out.extend_from_slice(data);
    out.extend(std::iter::repeat_n(pad as u8, pad));
    out
}

/// Go's `pkcs7Unpad`: only strip when the pad byte is in `(0, max]` and
/// `<= len`. Anything else is returned unchanged.
///
/// Kept for `decrypt_upstream`, which must reproduce the upstream wire
/// behavior exactly (a loose unpad there is a compatibility requirement,
/// not a choice). New callers that authenticate their own messages must
/// use [pkcs7_unpad_strict] instead.
pub fn pkcs7_unpad(data: &[u8], max: usize) -> &[u8] {
    if data.is_empty() {
        return data;
    }
    let pad = data[data.len() - 1] as usize;
    if pad > 0 && pad <= max && pad <= data.len() {
        return &data[..data.len() - pad];
    }
    data
}

/// Strict PKCS#7 unpad: the pad length must be in `1..=block`, the input
/// must be block-aligned, and *every* pad byte must equal the pad length.
/// Anything else is an error — never a silent pass-through.
///
/// A loose unpad lets a wrong key or tampered ciphertext "decrypt" to
/// attacker-influenced plaintext (garbage + a plausible-looking pad byte
/// is stripped and the rest is trusted). Use this on the register-key,
/// CM, and DH paths, where a bad pad means the message is not ours.
pub fn pkcs7_unpad_strict(data: &[u8], block: usize) -> Result<&[u8], String> {
    if data.is_empty() {
        return Err("pkcs7: empty input".to_string());
    }
    if !data.len().is_multiple_of(block) {
        return Err(format!(
            "pkcs7: input length {} not a multiple of block {block}",
            data.len()
        ));
    }
    let pad = data[data.len() - 1] as usize;
    if pad == 0 || pad > block || pad > data.len() {
        return Err(format!("pkcs7: invalid pad length {pad}"));
    }
    if !data[data.len() - pad..].iter().all(|&b| b as usize == pad) {
        return Err("pkcs7: pad bytes disagree".to_string());
    }
    Ok(&data[..data.len() - pad])
}

/// AES-CBC encrypt. `data` must already be block aligned.
pub fn aes_cbc_encrypt(data: &[u8], key: &[u8], iv: &[u8]) -> Vec<u8> {
    assert!(
        data.len().is_multiple_of(BLOCK),
        "aes-cbc input not block aligned"
    );
    let mut out = data.to_vec();
    match key.len() {
        16 => {
            let mut enc = Enc128::new_from_slices(key, iv).expect("aes128 cbc");
            for chunk in out.chunks_mut(BLOCK) {
                enc.encrypt_block_mut(GenericArray::from_mut_slice(chunk));
            }
        }
        32 => {
            let mut enc = Enc256::new_from_slices(key, iv).expect("aes256 cbc");
            for chunk in out.chunks_mut(BLOCK) {
                enc.encrypt_block_mut(GenericArray::from_mut_slice(chunk));
            }
        }
        n => panic!("unsupported AES key length {n}"),
    }
    out
}

/// AES-CBC decrypt. `data` must already be block aligned.
pub fn aes_cbc_decrypt(data: &[u8], key: &[u8], iv: &[u8]) -> Vec<u8> {
    assert!(
        data.len().is_multiple_of(BLOCK),
        "aes-cbc input not block aligned"
    );
    let mut out = data.to_vec();
    match key.len() {
        16 => {
            let mut dec = Dec128::new_from_slices(key, iv).expect("aes128 cbc");
            for chunk in out.chunks_mut(BLOCK) {
                dec.decrypt_block_mut(GenericArray::from_mut_slice(chunk));
            }
        }
        32 => {
            let mut dec = Dec256::new_from_slices(key, iv).expect("aes256 cbc");
            for chunk in out.chunks_mut(BLOCK) {
                dec.decrypt_block_mut(GenericArray::from_mut_slice(chunk));
            }
        }
        n => panic!("unsupported AES key length {n}"),
    }
    out
}

/// Maximum inflated size for any gzip payload we accept (API responses).
/// A gzip bomb (tiny input, huge output) must fail instead of eating all
/// memory: every inflate path goes through [gunzip_capped].
pub const MAX_GUNZIP_BYTES: usize = 64 * 1024 * 1024;

/// Why a gzip inflate failed. Callers that must not mistake a bomb for
/// "not gzip" match on [GunzipError::OverLimit].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GunzipError {
    /// Inflated output would exceed the cap.
    OverLimit,
    /// Not gzip, truncated, or checksum failure.
    Corrupt(String),
}

impl std::fmt::Display for GunzipError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GunzipError::OverLimit => {
                write!(f, "gunzip output exceeds {MAX_GUNZIP_BYTES} bytes")
            }
            GunzipError::Corrupt(e) => write!(f, "gunzip: {e}"),
        }
    }
}

/// gzip inflate with a hard output cap. `Take(limit + 1)` proves an
/// over-limit output after reading at most one byte past the cap, without
/// ever materializing the full bomb.
pub fn gunzip_capped(data: &[u8], limit: usize) -> Result<Vec<u8>, GunzipError> {
    use std::io::Read;
    let mut decoder = flate2::read::GzDecoder::new(data);
    let mut out = Vec::new();
    decoder
        .by_ref()
        .take(limit as u64 + 1)
        .read_to_end(&mut out)
        .map_err(|e| GunzipError::Corrupt(e.to_string()))?;
    if out.len() > limit {
        return Err(GunzipError::OverLimit);
    }
    Ok(out)
}

/// gzip inflate, returning None when the input is not gzip (or is corrupt
/// or over the cap).
pub fn gunzip(data: &[u8]) -> Option<Vec<u8>> {
    gunzip_capped(data, MAX_GUNZIP_BYTES).ok()
}

/// gzip deflate with flate2's default level (matches Go's `gzip.NewWriter`).
pub fn gzip(data: &[u8]) -> Vec<u8> {
    use std::io::Write;
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    let _ = encoder.write_all(data);
    encoder.finish().unwrap_or_default()
}

/// Go's `upstream.Decrypt`: base64 -> [iv:16][ct] -> AES-128-CBC -> strip pad
/// -> optional gzip inflate.
pub fn decrypt_upstream(encrypted_b64: &str, secret_key_hex: &str) -> Result<Vec<u8>, String> {
    use base64::Engine as _;
    let raw = base64::engine::general_purpose::STANDARD
        .decode(encrypted_b64)
        .map_err(|e| format!("base64: {e}"))?;
    if raw.len() < 16 {
        return Err(format!("ciphertext too short: {}", raw.len()));
    }
    let key = hex::decode(secret_key_hex).map_err(|_| "bad secret key".to_string())?;
    if key.len() != 16 {
        return Err("bad secret key".to_string());
    }
    let iv = &raw[..16];
    let ct = &raw[16..];
    if ct.len() % BLOCK != 0 {
        return Err(format!("ciphertext not block-aligned: {}", ct.len()));
    }
    let mut pt = aes_cbc_decrypt(ct, &key, iv);
    let unpadded = pkcs7_unpad(&pt, BLOCK).to_vec();
    pt = unpadded;
    // Only inflate when the plaintext actually carries the gzip magic.
    // An over-limit (or corrupt) gzip payload is an error, never a silent
    // fallback to returning compressed bytes as plaintext.
    if pt.len() >= 2 && pt[0] == 0x1f && pt[1] == 0x8b {
        return gunzip_capped(&pt, MAX_GUNZIP_BYTES).map_err(|e| e.to_string());
    }
    Ok(pt)
}

#[cfg(test)]
mod gunzip_cap_tests {
    use super::*;

    #[test]
    fn round_trip_under_the_cap() {
        let plain = b"hello gzip world".repeat(100);
        let compressed = gzip(&plain);
        assert_eq!(gunzip_capped(&compressed, 1024 * 1024).unwrap(), plain);
        assert_eq!(gunzip(&compressed).unwrap(), plain);
    }

    #[test]
    fn bomb_over_the_cap_is_an_error_not_a_huge_allocation() {
        // 1 MiB of zeros compresses to ~1 KiB; a 1 KiB cap must reject it.
        let plain = vec![0u8; 1024 * 1024];
        let compressed = gzip(&plain);
        assert!(compressed.len() < 4096);
        assert_eq!(
            gunzip_capped(&compressed, 1024),
            Err(GunzipError::OverLimit)
        );
        assert_eq!(gunzip(&compressed).unwrap(), plain);
    }

    #[test]
    fn non_gzip_input_is_corrupt_not_over_limit() {
        assert!(matches!(
            gunzip_capped(b"plain text, not gzip", 1024),
            Err(GunzipError::Corrupt(_))
        ));
        assert_eq!(gunzip(b"plain text, not gzip"), None);
    }

    #[test]
    fn decrypt_upstream_inflates_gzip_plaintext_under_the_cap() {
        // Build a decrypt_upstream input whose plaintext is a gzip bomb:
        // base64(iv || AES-128-CBC(pkcs7(gzip(zeros)))) with a known key.
        let key_hex = "00112233445566778899aabbccddeeff";
        let key = hex::decode(key_hex).expect("key");
        let bomb = gzip(&vec![0u8; 1024 * 1024]);
        let padded = pkcs7_pad(&bomb, BLOCK);
        let iv = [7u8; 16];
        let ct = aes_cbc_encrypt(&padded, &key, &iv);
        let mut raw = iv.to_vec();
        raw.extend_from_slice(&ct);
        use base64::Engine as _;
        let b64 = base64::engine::general_purpose::STANDARD.encode(raw);
        // decrypt_upstream inflates with the 64 MiB cap, so a 1 MiB bomb
        // still decrypts (it is under the cap); assert the inflate path
        // itself ran by comparing against the bomb output.
        let out = decrypt_upstream(&b64, key_hex).expect("1 MiB is under cap");
        assert_eq!(out, vec![0u8; 1024 * 1024]);
    }
}

#[cfg(test)]
mod strict_unpad_tests {
    use super::*;

    #[test]
    fn valid_padding_strips() {
        // One full block: "abc" + 13 pad bytes of 0x0d.
        let mut padded = b"abc".to_vec();
        padded.extend(std::iter::repeat_n(13u8, 13));
        assert_eq!(pkcs7_unpad_strict(&padded, 16).unwrap(), b"abc");
        assert_eq!(pkcs7_unpad_strict(&pkcs7_pad(b"", 16), 16).unwrap(), b"");
    }

    #[test]
    fn inconsistent_pad_bytes_are_rejected() {
        // Last byte says 2, but only one pad byte matches.
        assert!(pkcs7_unpad_strict(b"abc\x01\x02", 16).is_err());
    }

    #[test]
    fn zero_pad_and_oversized_pad_are_rejected() {
        assert!(pkcs7_unpad_strict(b"abc\x00", 16).is_err());
        // Pad length 17 > block 16 (input padded to 32 for alignment).
        let mut bad = b"hello".to_vec();
        bad.extend(std::iter::repeat_n(17u8, 27));
        assert!(pkcs7_unpad_strict(&bad, 16).is_err());
    }

    #[test]
    fn empty_and_unaligned_inputs_are_rejected() {
        assert!(pkcs7_unpad_strict(b"", 16).is_err());
        assert!(pkcs7_unpad_strict(b"abc", 16).is_err());
    }
}
