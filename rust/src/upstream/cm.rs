//! CM handshake (3072-bit MODP, RFC 3526 group 15) used by the full API.

use std::sync::Arc;

use base64::Engine as _;
use num_bigint::BigUint;
use num_traits::Zero;
use once_cell::sync::OnceCell;
use rand::Rng;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

// Hold the permit inside the blocking task: cancelling its caller cannot
// stop a running modpow and must not free the slot prematurely.
static CM_WORK: once_cell::sync::Lazy<Arc<tokio::sync::Semaphore>> =
    once_cell::sync::Lazy::new(|| Arc::new(tokio::sync::Semaphore::new(2)));

const CM_PRIME_HEX: &str = "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca237327ffffffffffffffff";

fn cm_prime() -> &'static BigUint {
    static P: OnceCell<BigUint> = OnceCell::new();
    P.get_or_init(|| BigUint::parse_bytes(CM_PRIME_HEX.as_bytes(), 16).expect("cm prime"))
}

/// Subgroup order `q = (p - 1) / 2`.
///
/// Not secret and identical for every handshake, so it is derived once: the
/// peer-key subgroup check exponentiates with it on every decrypt.
fn cm_prime_order() -> &'static BigUint {
    static Q: OnceCell<BigUint> = OnceCell::new();
    Q.get_or_init(|| (cm_prime() - BigUint::from(1u32)) / BigUint::from(2u32))
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
///
/// Secrets are zeroized on drop: the private key lives in a
/// `Zeroizing<Vec<u8>>` (a `BigUint` has no `Zeroize` impl, so it is never
/// stored directly), and the request AES key / IV are wiped with it.
/// The public key is not secret, but it is kept as bytes so the whole
/// struct can derive `ZeroizeOnDrop`.
#[derive(Debug, Clone, Zeroize, ZeroizeOnDrop)]
pub struct CM {
    private_key: Zeroizing<Vec<u8>>,
    public_key: Vec<u8>,
    aes_key: Vec<u8>,
    iv: [u8; 16],
}

impl CM {
    pub async fn new_off_thread() -> Result<Self, String> {
        let permit = Arc::clone(&CM_WORK)
            .acquire_owned()
            .await
            .map_err(|e| e.to_string())?;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            Self::new()
        })
        .await
        .map_err(|e| format!("cm init task failed: {e}"))?
    }

    pub fn new() -> Result<Self, String> {
        let mut rng = rand::thread_rng();
        let priv_bytes: [u8; 32] = rng.gen();
        let iv: [u8; 16] = rng.gen();
        let p_minus_1 = cm_prime() - BigUint::from(1u32);
        let private_key = BigUint::from_bytes_be(&priv_bytes) % p_minus_1;
        let public_key = cm_base().modpow(&private_key, cm_prime());

        Ok(CM {
            private_key: Zeroizing::new(private_key.to_bytes_be()),
            public_key: gmp_to_bytes(&public_key),
            // base64 "rCXGfd2POMGzeiNIgo4iLg=="
            aes_key: crate::upstream::dh::dh_req_key(),
            iv,
        })
    }

    /// `base64(iv + AES-128-CBC(pkcs7(pubKeyBytes)))` for the body's "key" field.
    pub fn client_handshake(&self) -> String {
        let y_bytes = self.public_key.clone();
        let padded = crate::crypto::pkcs7_pad(&y_bytes, 16);
        let ct = crate::crypto::aes_cbc_encrypt(&padded, &self.aes_key, &self.iv);
        let mut blob = self.iv.to_vec();
        blob.extend_from_slice(&ct);
        base64::engine::general_purpose::STANDARD.encode(blob)
    }

    /// Decrypts one chapter given the per-item server key (base64).
    ///
    /// Synchronous because it is also the unit-test entry point; the shipping
    /// API path uses [CM::decrypt_off_thread], which runs this on the blocking
    /// pool: the peer-subgroup check and the 3072-bit shared-secret
    /// exponentiation are milliseconds of CPU work that must not occupy an
    /// async worker.
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
        // P2-10: never derive a shared secret from an unvalidated peer
        // value — a degenerate y collapses the secret to a known value.
        crate::upstream::validate_peer_pubkey(&server_key, cm_prime(), cm_prime_order())?;
        let private_key = BigUint::from_bytes_be(&self.private_key);
        let shared = server_key.modpow(&private_key, cm_prime());

        let shared_bytes = gmp_to_bytes(&shared);
        if shared_bytes.len() < 32 {
            return Err(format!("shared secret too short: {}", shared_bytes.len()));
        }
        let aes_key = &shared_bytes[..32];

        if ct.len() % 16 != 0 {
            return Err("content not block-aligned".to_string());
        }
        let pt = crate::crypto::aes_cbc_decrypt(ct, aes_key, iv);
        Ok(crate::crypto::pkcs7_unpad_strict(&pt, 16)?.to_vec())
    }

    /// [CM::decrypt] on the blocking pool.
    ///
    /// The `Arc` is moved (not the secret fields), so the per-handshake key
    /// material stays in one allocation and is zeroized when the last handle
    /// drops.
    pub async fn decrypt_off_thread(
        self: &Arc<Self>,
        server_key_b64: &str,
        content_b64: &str,
    ) -> Result<Vec<u8>, String> {
        let server_key_b64 = server_key_b64.to_owned();
        let content_b64 = content_b64.to_owned();
        self.process_off_thread(move |cm| cm.decrypt(&server_key_b64, &content_b64))
            .await
    }

    /// Keep decrypt and its CPU-heavy consumer in one bounded blocking task.
    pub(crate) async fn process_off_thread<T, F>(self: &Arc<Self>, process: F) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce(&Self) -> Result<T, String> + Send + 'static,
    {
        let queued = std::time::Instant::now();
        let permit = Arc::clone(&CM_WORK)
            .acquire_owned()
            .await
            .map_err(|e| e.to_string())?;
        let cm = Arc::clone(self);
        match tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let wait_ms = queued.elapsed().as_millis();
            let started = std::time::Instant::now();
            let result = process(&cm);
            let work_ms = started.elapsed().as_millis();
            if wait_ms + work_ms >= 100 {
                log::info!("cm slow: queue_ms={wait_ms} work_ms={work_ms}");
            }
            result
        })
        .await
        {
            Ok(result) => result,
            Err(error) => Err(format!("decrypt task failed: {error}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Encrypts `plain` the way the upstream does: a peer key
    /// `B = g^b mod p`, the shared secret `Y^b`, and AES-CBC keyed by its
    /// first 32 bytes.
    fn peer_encrypt(cm: &CM, plain: &[u8]) -> (String, String) {
        let p = cm_prime();
        let mut rng = rand::thread_rng();
        let b_bytes: [u8; 32] = rng.gen();
        let b = BigUint::from_bytes_be(&b_bytes) % (p - BigUint::from(1u32));
        let peer_public = cm_base().modpow(&b, p);
        let client_public = BigUint::from_bytes_be(&cm.public_key);
        let shared = client_public.modpow(&b, p);
        let shared_bytes = gmp_to_bytes(&shared);
        assert!(shared_bytes.len() >= 32, "shared secret must fill the key");

        let iv: [u8; 16] = rng.gen();
        let padded = crate::crypto::pkcs7_pad(plain, 16);
        let ct = crate::crypto::aes_cbc_encrypt(&padded, &shared_bytes[..32], &iv);
        let mut blob = iv.to_vec();
        blob.extend_from_slice(&ct);
        (
            base64::engine::general_purpose::STANDARD.encode(gmp_to_bytes(&peer_public)),
            base64::engine::general_purpose::STANDARD.encode(blob),
        )
    }

    // The shipping path decrypts on the blocking pool; it must accept a real
    // 3072-bit peer key and produce exactly what the synchronous path does.
    #[tokio::test]
    async fn the_off_thread_decrypt_matches_the_sync_path() {
        let cm = Arc::new(CM::new().expect("cm"));
        let plain = b"chapter body decrypted off the async worker";
        let (key, content) = peer_encrypt(&cm, plain);

        let sync_plain = cm.decrypt(&key, &content).expect("sync decrypt");
        assert_eq!(sync_plain, plain);
        let offloaded = cm
            .decrypt_off_thread(&key, &content)
            .await
            .expect("off-thread decrypt");
        assert_eq!(offloaded, sync_plain);
    }

    // The point of the offload: while the 3072-bit work runs, the runtime must
    // be free to poll other tasks. An inline implementation would leave this
    // spawned task untouched until after the decrypt returned.
    #[tokio::test(flavor = "current_thread")]
    async fn the_off_thread_decrypt_yields_to_the_runtime() {
        use std::sync::atomic::{AtomicBool, Ordering};

        let cm = Arc::new(CM::new().expect("cm"));
        let (key, content) = peer_encrypt(&cm, b"chapter body");
        let polled = Arc::new(AtomicBool::new(false));
        let setter = polled.clone();
        tokio::spawn(async move { setter.store(true, Ordering::SeqCst) });

        cm.decrypt_off_thread(&key, &content)
            .await
            .expect("off-thread decrypt");
        assert!(
            polled.load(Ordering::SeqCst),
            "the exponentiation must not run inline on the async worker"
        );
    }

    // The cached intermediate must describe the same group as the prime; a
    // stale or mis-derived order would silently reject every peer key.
    #[test]
    fn the_cached_subgroup_order_matches_the_prime() {
        let p = cm_prime();
        let q = cm_prime_order();
        assert_eq!(p, &(q * BigUint::from(2u32) + BigUint::from(1u32)));
        assert!(
            std::ptr::eq(q, cm_prime_order()),
            "the subgroup order must be computed once"
        );
    }
}
