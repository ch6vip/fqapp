//! Signed upstream HTTP access, device rotation, DH/CM key exchange.

pub mod client;
pub mod cm;
pub mod dh;
pub mod http;
pub mod shuqi;

pub use client::{ClientError, PinnedDevice, UpstreamClient, UpstreamRequest};
pub use http::{HttpTransport, RawResponse, TransportError};

use num_bigint::BigUint;
use num_traits::One;

/// Validates a peer's DH/CM public value `y` against the group prime `p`
/// before any shared secret is derived from it.
///
/// `q` is the prime-order subgroup order `(p - 1) / 2`. Callers cache it per
/// group (see `cm.rs` / `dh.rs`): it is fixed for a prime and involves no
/// per-session secret, so no handshake needs to derive it again.
///
/// Rejects degenerate values without changing the wire format:
/// - out of range (`2 <= y <= p - 2`): excludes 0, 1, p-1, p and anything
///   above the field (this already covers the identity and the order-2
///   element);
/// - small-subgroup values: for the safe primes used here (`p = 2q + 1`),
///   a legitimate peer value lies in the prime-order subgroup, i.e.
///   `y^q == 1 (mod p)`. Anything else would pull the shared secret into
///   a tiny subgroup an attacker can enumerate.
///
/// This is a 3071-bit exponentiation, so both callers run it on the blocking
/// pool rather than on an async worker. A rejected value is a hard error,
/// never a silent fallback.
pub fn validate_peer_pubkey(y: &BigUint, p: &BigUint, q: &BigUint) -> Result<(), String> {
    let two = BigUint::from(2u32);
    let p_minus_2 = p - &two;
    // Excludes 0, 1, p - 1, p and anything above the field.
    if y < &two || y > &p_minus_2 {
        return Err("peer public key out of range".to_string());
    }
    // Small-subgroup check: require y^q == 1 mod p.
    if y.modpow(q, p) != BigUint::one() {
        return Err("peer public key is not in the prime-order subgroup".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod peer_pubkey_tests {
    use super::*;

    // Small safe prime for tests: p = 2*11 + 1 = 23, q = 11.
    fn p() -> BigUint {
        BigUint::from(23u32)
    }

    fn q() -> BigUint {
        BigUint::from(11u32)
    }

    #[test]
    fn accepts_subgroup_members() {
        // 2 is a generator of the order-11 subgroup mod 23 (2^11 == 1).
        assert!(validate_peer_pubkey(&BigUint::from(2u32), &p(), &q()).is_ok());
        assert!(validate_peer_pubkey(&BigUint::from(4u32), &p(), &q()).is_ok());
    }

    #[test]
    fn rejects_degenerate_and_out_of_range_values() {
        for bad in [0u32, 1, 22, 23, 24, 100] {
            assert!(
                validate_peer_pubkey(&BigUint::from(bad), &p(), &q()).is_err(),
                "{bad} must be rejected"
            );
        }
    }

    #[test]
    fn rejects_small_subgroup_values() {
        // 5 is in range [2, p-2] but is a quadratic non-residue mod 23,
        // so 5^11 == 22 != 1: only the subgroup check rejects it.
        assert!(validate_peer_pubkey(&BigUint::from(5u32), &p(), &q()).is_err());
    }
}
