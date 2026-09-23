//! CM handshake (3072-bit MODP, RFC 3526 group 15) used by the full API.
//! Port of `/internal/upstream/cm.go`.

use base64::Engine as _;
use num_bigint::BigUint;
use num_traits::Zero;
use once_cell::sync::OnceCell;
use rand::Rng;

const CM_PRIME_HEX: &str = "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca237327ffffffffffffffff";

fn cm_prime() -> &'static BigUint {
    static P: OnceCell<BigUint> = OnceCell::new();
    P.get_or_init(|| BigUint::parse_bytes(CM_PRIME_HEX.as_bytes(), 16).expect("cm prime"))
}

fn cm_base() -> BigUint {
    BigUint::from(2u32)
}

pub fn gmp_to_bytes(n: &BigUint) -> Vec<u8> {
    if n.is_zero() {
        Vec::new()
    } else {
        n.to_bytes_be()
    }
}

/// One handshake's private/public key state.
#[derive(Debug, Clone)]
pub struct CM {
    private_key: BigUint,
    public_key: BigUint,
    aes_key: Vec<u8>,
    iv: [u8; 16],
}

impl CM {
    pub fn new() -> Result<Self, String> {
        let mut rng = rand::thread_rng();
        let priv_bytes: [u8; 32] = rng.gen();
        let iv: [u8; 16] = rng.gen();
        let p_minus_1 = cm_prime() - BigUint::from(1u32);
        let private_key = BigUint::from_bytes_be(&priv_bytes) % p_minus_1;
        let public_key = cm_base().modpow(&private_key, cm_prime());

        Ok(CM {
            private_key,
            public_key,
            // base64 "rCXGfd2POMGzeiNIgo4iLg=="
            aes_key: crate::upstream::dh::dh_req_key(),
            iv,
        })
    }

    /// `base64(iv + AES-128-CBC(pkcs7(pubKeyBytes)))` for the body's "key" field.
    pub fn client_handshake(&self) -> String {
        let y_bytes = gmp_to_bytes(&self.public_key);
        let padded = crate::crypto::pkcs7_pad(&y_bytes, 16);
        let ct = crate::crypto::aes_cbc_encrypt(&padded, &self.aes_key, &self.iv);
        let mut blob = self.iv.to_vec();
        blob.extend_from_slice(&ct);
        base64::engine::general_purpose::STANDARD.encode(blob)
    }

    /// Decrypts one chapter given the per-item server key (base64).
    pub fn decrypt(&self, server_key_b64: &str, content_b64: &str) -> Result<Vec<u8>, String> {
        if server_key_b64.is_empty() || content_b64.is_empty() {
            return Err("empty key or content".to_string());
        }
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(content_b64)
            .map_err(|e| format!("decode content: {e}"))?;
        if decoded.len() < 16 {
            return Err("content too short".to_string());
        }
        let iv = &decoded[..16];
        let ct = &decoded[16..];

        let server_key_bytes = base64::engine::general_purpose::STANDARD
            .decode(server_key_b64)
            .map_err(|e| format!("decode server key: {e}"))?;
        let server_key = BigUint::from_bytes_be(&server_key_bytes);
        let shared = server_key.modpow(&self.private_key, cm_prime());

        let shared_bytes = gmp_to_bytes(&shared);
        if shared_bytes.len() < 32 {
            return Err(format!("shared secret too short: {}", shared_bytes.len()));
        }
        let aes_key = &shared_bytes[..32];

        if ct.len() % 16 != 0 {
            return Err("content not block-aligned".to_string());
        }
        let pt = crate::crypto::aes_cbc_decrypt(ct, aes_key, iv);
        Ok(crate::crypto::pkcs7_unpad(&pt, 16).to_vec())
    }
}
