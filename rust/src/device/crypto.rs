//! Pure crypto helpers for device registration.
//! Port of `/internal/device/crypto.go`.

use base64::Engine as _;
use rand::Rng;
use sha2::{Digest, Sha512};

const TT_FIXED_STRING_B64: &str =
    "TdTC5rgxYgkOUrPHpnM7pByyRiuCmrWKGWs521cXdST0m69/COjWjSanLjfBqVovHwWlGJKu8pSXMrYqOKrdWA==";
const TT_MAGIC: [u8; 6] = [0x74, 0x63, 0x05, 0x10, 0x00, 0x00];

const REGISTER_KEY_MASTER_HEX: &str = "ac25c67ddd8f38c1b37a2348828e222e";
const REGISTER_KEY_REQ_KEY_B64: &str = "rCXGfd2POMGzeiNIgo4iLg==";
const ALNUM_CHARS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// Encrypts the request payload.
/// key/iv = SHA512(SHA512(random32) + fixedString)[0:16], [16:32].
/// Output = magic + random32 + AES-128-CBC(PKCS7(SHA512(data) + data)).
pub fn tt_encrypt(data: &[u8], random_bytes32: Option<[u8; 32]>) -> Result<Vec<u8>, String> {
    let random_bytes32 = match random_bytes32 {
        Some(b) => b,
        None => rand::thread_rng().gen::<[u8; 32]>(),
    };
    let fixed = base64::engine::general_purpose::STANDARD
        .decode(TT_FIXED_STRING_B64)
        .map_err(|e| e.to_string())?;

    let inner = Sha512::digest(random_bytes32);
    let mut hasher = Sha512::new();
    hasher.update(inner);
    hasher.update(&fixed);
    let hv = hasher.finalize();
    let aes_key = &hv[0..16];
    let aes_iv = &hv[16..32];

    let data_hash = Sha512::digest(data);
    let mut hashed_data = data_hash.to_vec();
    hashed_data.extend_from_slice(data);

    let padded = crate::crypto::pkcs7_pad(&hashed_data, 16);
    let enc = crate::crypto::aes_cbc_encrypt(&padded, aes_key, aes_iv);

    let mut out = TT_MAGIC.to_vec();
    out.extend_from_slice(&random_bytes32);
    out.extend_from_slice(&enc);
    Ok(out)
}

/// Decrypts a registerkey response `data.key` into the raw secret-key bytes.
pub fn decrypt_register_key(encrypted_key_b64: &str) -> Result<Vec<u8>, String> {
    // Note: reject malformed upstream blocks before the CBC helper asserts —
    // see .agents/notes/implemented/bug-fix/2026-09-28-registerkey-ciphertext.md.
    let data = base64::engine::general_purpose::STANDARD
        .decode(encrypted_key_b64)
        .map_err(|e| e.to_string())?;
    if data.len() < 16 {
        return Err(format!("registerkey data too short: {}", data.len()));
    }
    let key = hex::decode(REGISTER_KEY_MASTER_HEX).expect("master key");
    let iv = &data[..16];
    let ct = &data[16..];
    // An empty ciphertext is block-aligned but would yield an empty key that
    // only surfaces later as a confusing signature failure — reject it here.
    if ct.is_empty() {
        return Err("registerkey ciphertext empty".to_string());
    }
    if !ct.len().is_multiple_of(crate::crypto::BLOCK) {
        return Err("registerkey ciphertext not block-aligned".to_string());
    }
    let pt = crate::crypto::aes_cbc_decrypt(ct, &key, iv);
    Ok(crate::crypto::pkcs7_unpad(&pt, 16).to_vec())
}

/// `base64(iv + AES-128-CBC-PKCS7(hex2bin(reverseHex(deviceId))))`.
pub fn encrypt_register_key_request(device_id: &str, iv: Option<&[u8]>) -> Result<String, String> {
    let key = base64::engine::general_purpose::STANDARD
        .decode(REGISTER_KEY_REQ_KEY_B64)
        .map_err(|e| e.to_string())?;
    if key.len() != 16 {
        return Err(format!("registerkey req key len {}", key.len()));
    }
    let iv = match iv {
        Some(v) => v.to_vec(),
        None => random_alnum(16),
    };
    let hex_data = reverse_hex(device_id);
    let raw = hex::decode(&hex_data).map_err(|e| e.to_string())?;
    let padded = crate::crypto::pkcs7_pad(&raw, 16);
    let enc = crate::crypto::aes_cbc_encrypt(&padded, &key, &iv);
    let mut blob = iv;
    blob.extend_from_slice(&enc);
    Ok(base64::engine::general_purpose::STANDARD.encode(blob))
}

/// Left-pads the decimal id's hex to 32 chars, then reverses byte pairs.
pub fn reverse_hex(device_id: &str) -> String {
    let n: u64 = device_id.parse().unwrap_or(0);
    let h = format!("{n:032x}");
    let bytes = h.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(32);
    let mut i = bytes.len();
    while i >= 2 {
        out.push(bytes[i - 2]);
        out.push(bytes[i - 1]);
        i -= 2;
    }
    String::from_utf8(out).unwrap_or_default()
}

/// n random alphanumeric bytes (matches the iv/openudid generator).
pub fn random_alnum(n: usize) -> Vec<u8> {
    let mut b: Vec<u8> = rand::thread_rng()
        .sample_iter(rand::distributions::Standard)
        .take(n)
        .collect();
    for x in b.iter_mut() {
        *x = ALNUM_CHARS[(*x as usize) % ALNUM_CHARS.len()];
    }
    b
}

pub fn random_hex_lower(n: usize) -> String {
    const HEX_L: &[u8] = b"0123456789abcdef";
    let mut rng = rand::thread_rng();
    (0..n)
        .map(|_| HEX_L[rng.gen_range(0..16usize)] as char)
        .collect()
}

pub fn uuid_v4() -> String {
    let mut rng = rand::thread_rng();
    let a: u32 = rng.gen_range(0..0x10000);
    let b: u32 = rng.gen_range(0..0x10000);
    let c: u32 = rng.gen_range(0..0x10000);
    let d: u32 = rng.gen_range(0..0x1000) | 0x4000;
    let e: u32 = rng.gen_range(0..0x4000) | 0x8000;
    let f: u32 = rng.gen_range(0..0x10000);
    let g: u32 = rng.gen_range(0..0x10000);
    let h: u32 = rng.gen_range(0..0x10000);
    format!("{a:04x}{b:04x}-{c:04x}-{d:04x}-{e:04x}-{f:04x}{g:04x}{h:04x}")
}

pub fn rand_mac() -> String {
    const HEX_U: &[u8] = b"0123456789ABCDEF";
    let mut rng = rand::thread_rng();
    let mut out = String::new();
    for i in 0..6 {
        if i > 0 {
            out.push(':');
        }
        out.push(HEX_U[rng.gen_range(0..16usize)] as char);
        out.push(HEX_U[rng.gen_range(0..16usize)] as char);
    }
    out
}
