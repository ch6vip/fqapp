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

/// gzip inflate, returning None when the input is not gzip.
pub fn gunzip(data: &[u8]) -> Option<Vec<u8>> {
    use std::io::Read;
    let mut decoder = flate2::read::GzDecoder::new(data);
    let mut out = Vec::new();
    match decoder.read_to_end(&mut out) {
        Ok(_) => Some(out),
        Err(_) => None,
    }
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
    if let Some(inflated) = gunzip(&pt) {
        return Ok(inflated);
    }
    Ok(pt)
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
        assert_eq!(
            pkcs7_unpad_strict(&pkcs7_pad(b"", 16), 16).unwrap(),
            b""
        );
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
