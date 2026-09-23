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
