//! Recommendation session -> device pinning.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use serde_json::Value;

use crate::device::DevicePool;

pub const DEVICE_SESSION_TTL: Duration = Duration::from_secs(10 * 60);

/// Upper bound on tracked device sessions. Sessions are short-lived (TTL
/// 10 min) and keyed by upstream-issued ids, so the map stays small in
/// practice; the cap is only a backstop against unbounded growth from ids
/// that are never looked up again.
const MAX_DEVICE_SESSIONS: usize = 10_000;

struct Entry {
    device_id: String,
    expires: Instant,
}

static DEVICE_SESSIONS: Lazy<Mutex<HashMap<String, Entry>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Drops entries whose TTL has passed. Called opportunistically on lookup
/// and on insert, so expired entries do not linger until their own id
/// happens to be looked up.
fn evict_expired(m: &mut HashMap<String, Entry>, now: Instant) {
    m.retain(|_, e| e.expires > now);
}

/// Drops the stalest entries (earliest expiry ≈ oldest insert, since the
/// TTL is fixed) until the map fits the cap.
fn evict_oldest(m: &mut HashMap<String, Entry>) {
    while m.len() > MAX_DEVICE_SESSIONS {
        let Some(oldest) = m
            .iter()
            .min_by_key(|(_, e)| e.expires)
            .map(|(k, _)| k.clone())
        else {
            break;
        };
        m.remove(&oldest);
    }
}

/// Binds `session_id` to the device that answered the request that created it.
pub fn record_device_session(session_id: &str, device_id: &str) {
    if session_id.is_empty() || device_id.is_empty() {
        return;
    }
    if let Ok(mut m) = DEVICE_SESSIONS.lock() {
        // Make room first: expired entries go, then the stalest ones, so
        // the map stays bounded even if ids are never looked up again.
        // The just-inserted entry has the latest expiry, so the cap
        // eviction below never drops it.
        evict_expired(&mut m, Instant::now());
        m.insert(
            session_id.to_string(),
            Entry {
                device_id: device_id.to_string(),
                expires: Instant::now() + DEVICE_SESSION_TTL,
            },
        );
        evict_oldest(&mut m);
    }
}

/// Returns the pooled device a session is bound to, when still known and still
/// present in the pool.
pub async fn device_key_from_session(session_id: &str, pool: &DevicePool) -> Option<String> {
    if session_id.is_empty() {
        return None;
    }
    let entry = {
        let mut m = DEVICE_SESSIONS.lock().ok()?;
        // Opportunistic sweep: a lookup touches the map anyway, so expired
        // entries piggyback on it instead of lingering until their own id
        // is looked up.
        evict_expired(&mut m, Instant::now());
        m.get(session_id).map(|e| (e.device_id.clone(), e.expires))
    };
    let (device_id, expires) = entry?;
    if Instant::now() > expires {
        if let Ok(mut m) = DEVICE_SESSIONS.lock() {
            m.remove(session_id);
        }
        return None;
    }
    match pool.get_by_id(&device_id).await {
        Ok(_) => Some(device_id),
        Err(_) => None,
    }
}

/// Digs the upstream-created `session_id` out of a raw response.
pub fn session_id_from_response(raw: &[u8]) -> String {
    match serde_json::from_slice::<Value>(raw) {
        Ok(v) => find_session_id(&v),
        Err(_) => String::new(),
    }
}

fn find_session_id(node: &Value) -> String {
    match node {
        Value::Object(m) => {
            if let Some(Value::String(s)) = m.get("session_id") {
                if !s.is_empty() {
                    return s.clone();
                }
            }
            for child in m.values() {
                let s = find_session_id(child);
                if !s.is_empty() {
                    return s;
                }
            }
            String::new()
        }
        Value::Array(a) => {
            for child in a {
                let s = find_session_id(child);
                if !s.is_empty() {
                    return s;
                }
            }
            String::new()
        }
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(expires: Instant) -> Entry {
        Entry {
            device_id: "dev".to_string(),
            expires,
        }
    }

    /// P2-13: expired entries must be swept, live ones kept.
    #[test]
    fn evict_expired_drops_only_expired() {
        let now = Instant::now();
        let mut m: HashMap<String, Entry> = HashMap::new();
        m.insert("old".to_string(), entry(now - Duration::from_secs(1)));
        m.insert("live".to_string(), entry(now + Duration::from_secs(60)));
        evict_expired(&mut m, now);
        assert!(!m.contains_key("old"), "expired entry must be swept");
        assert!(m.contains_key("live"), "live entry must survive");
    }

    /// P2-13: over the cap, the stalest (earliest-expiry) entries go first.
    #[test]
    fn evict_oldest_keeps_newest_up_to_cap() {
        let now = Instant::now();
        let mut m: HashMap<String, Entry> = HashMap::new();
        for i in 0..MAX_DEVICE_SESSIONS + 5 {
            m.insert(format!("s{i}"), entry(now + Duration::from_secs(i as u64)));
        }
        evict_oldest(&mut m);
        assert_eq!(m.len(), MAX_DEVICE_SESSIONS, "map must fit the cap");
        for i in 0..5 {
            assert!(
                !m.contains_key(&format!("s{i}")),
                "stalest entry s{i} must be evicted"
            );
        }
        assert!(
            m.contains_key(&format!("s{}", MAX_DEVICE_SESSIONS + 4)),
            "newest entry must survive"
        );
    }

    /// P2-13: recording through the public path keeps the global map
    /// bounded even when ids are never looked up again.
    #[test]
    fn record_keeps_global_map_bounded() {
        for i in 0..MAX_DEVICE_SESSIONS + 50 {
            record_device_session(&format!("sess-{i}"), "dev");
        }
        let len = DEVICE_SESSIONS.lock().unwrap().len();
        assert_eq!(len, MAX_DEVICE_SESSIONS, "global map must fit the cap");
        // Leave no residue for other tests sharing this process.
        DEVICE_SESSIONS.lock().unwrap().clear();
    }
}
