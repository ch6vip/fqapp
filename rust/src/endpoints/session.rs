//! Recommendation session -> device pinning.
//! Port of `/internal/endpoints/device_session.go`.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use serde_json::Value;

use crate::device::DevicePool;

pub const DEVICE_SESSION_TTL: Duration = Duration::from_secs(10 * 60);

struct Entry {
    device_id: String,
    expires: Instant,
}

static DEVICE_SESSIONS: Lazy<Mutex<HashMap<String, Entry>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Binds `session_id` to the device that answered the request that created it.
pub fn record_device_session(session_id: &str, device_id: &str) {
    if session_id.is_empty() || device_id.is_empty() {
        return;
    }
    if let Ok(mut m) = DEVICE_SESSIONS.lock() {
        m.insert(
            session_id.to_string(),
            Entry {
                device_id: device_id.to_string(),
                expires: Instant::now() + DEVICE_SESSION_TTL,
            },
        );
    }
}

/// Returns the pooled device a session is bound to, when still known and still
/// present in the pool.
pub async fn device_key_from_session(session_id: &str, pool: &DevicePool) -> Option<String> {
    if session_id.is_empty() {
        return None;
    }
    let entry = {
        let m = DEVICE_SESSIONS.lock().ok()?;
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
