//! Toutiao/Full DH key-exchange decryption. Port of
//! `/internal/upstream/dh.go`.

use base64::Engine as _;
use num_bigint::{BigUint, RandBigInt};
use num_traits::Zero;
use once_cell::sync::OnceCell;

const DH_PRIME_DEC: &str = "2410312426921032588552076022197566074856950548502459942654116941958108831682612228890093858261341614673227141477904012196503648957050582631942730706805009223062734745341073406696246014589361659774041027169249453200378729434170325843778659198143763193776859869524088940195577346119843545301547043747207749969763750084308926339295559968882457872412993810129130294592999947926365264059284647209730384947211681434464714438488520940127459844288859336526896320919633919";

fn dh_prime() -> &'static BigUint {
    static P: OnceCell<BigUint> = OnceCell::new();
    P.get_or_init(|| BigUint::parse_bytes(DH_PRIME_DEC.as_bytes(), 10).expect("dh prime"))
}

fn dh_g() -> BigUint {
    BigUint::from(2u32)
}

/// Client private key for the follow-up decrypt.
#[derive(Debug, Clone)]
pub struct DHState {
    pub a: BigUint,
}

/// Java `BigInteger.toByteArray`: big-endian, leading 0x00 when the top bit is
/// set so the value stays positive.
pub fn java_big_int_bytes(n: &BigUint) -> Vec<u8> {
    if n.is_zero() {
        return Vec::new();
    }
    let b = n.to_bytes_be();
    if b[0] & 0x80 != 0 {
        let mut out = Vec::with_capacity(b.len() + 1);
        out.push(0);
        out.extend_from_slice(&b);
        out
    } else {
        b
    }
}

pub fn pkcs7_pad_to(data: &[u8], block: usize) -> Vec<u8> {
    crate::crypto::pkcs7_pad(data, block)
}

/// base64 "rCXGfd2POMGzeiNIgo4iLg=="
pub fn dh_req_key() -> Vec<u8> {
    base64::engine::general_purpose::STANDARD
        .decode("rCXGfd2POMGzeiNIgo4iLg==")
        .expect("dh request key")
}

/// Builds the "y" request header plus the DH state for the decrypt step.
pub fn generate_y() -> Result<(String, DHState), String> {
    let mut rng = rand::thread_rng();
    let a = rng.gen_biguint(256);
    let big_a = dh_g().modpow(&a, dh_prime());
    let a_bytes = java_big_int_bytes(&big_a);

    let iv: [u8; 16] = rand::Rng::gen(&mut rng);
    let padded = pkcs7_pad_to(&a_bytes, 16);
    let key = dh_req_key();
    let ct = crate::crypto::aes_cbc_encrypt(&padded, &key, &iv);

    let mut blob = iv.to_vec();
    blob.extend_from_slice(&ct);
    Ok((
        base64::engine::general_purpose::STANDARD.encode(blob),
        DHState { a },
    ))
}

/// Computes the shared secret from the server `y` header and decrypts the
/// AES-256-CBC content.
pub fn decrypt_dh_content(
    server_y_b64: &str,
    content_b64: &str,
    st: &DHState,
) -> Result<Vec<u8>, String> {
    let b_bytes = base64::engine::general_purpose::STANDARD
        .decode(server_y_b64)
        .map_err(|e| format!("decode server y: {e}"))?;
    let b = BigUint::from_bytes_be(&b_bytes);
    let s = b.modpow(&st.a, dh_prime());
    let s_bytes = if s.is_zero() {
        Vec::new()
    } else {
        s.to_bytes_be()
    };

    if s_bytes.len() < 32 {
        return Err(format!("shared secret too short: {}", s_bytes.len()));
    }
    // The FIRST 32 bytes of the shared secret (s is ~384 bytes here).
    let key = &s_bytes[..32];

    let content = base64::engine::general_purpose::STANDARD
        .decode(content_b64)
        .map_err(|e| format!("decode content: {e}"))?;
    if content.len() < 16 {
        return Err(format!("content too short: {}", content.len()));
    }
    let iv = &content[..16];
    let ct = &content[16..];
    if ct.len() % 16 != 0 {
        return Err(format!("content not block-aligned: {}", ct.len()));
    }
    let pt = crate::crypto::aes_cbc_decrypt(ct, key, iv);
    Ok(crate::crypto::pkcs7_unpad(&pt, 16).to_vec())
}
