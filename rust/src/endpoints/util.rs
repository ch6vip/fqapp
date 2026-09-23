//! Shared endpoint helpers, ported from `content_util.go` / `base.go`.

use serde_json::Value;

/// Go's query-component escaping with the unreserved set
/// `A-Za-z0-9-_.~` and '+' for spaces.
pub fn go_query_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn restore_placeholders(q: &str) -> String {
    q.replace("%7Bdevice_id%7D", "{device_id}")
        .replace("%7Binstall_id%7D", "{install_id}")
        .replace("%7Bsecret_key%7D", "{secret_key}")
}

/// Go's `encodeQuery`: sorted keys, escaped, device placeholders restored.
pub fn encode_query(items: &[(String, String)]) -> String {
    let mut v = items.to_vec();
    v.sort_by(|a, b| a.0.cmp(&b.0));
    let joined = v
        .iter()
        .map(|(k, val)| format!("{}={}", go_query_escape(k), go_query_escape(val)))
        .collect::<Vec<_>>()
        .join("&");
    restore_placeholders(&joined)
}

/// Go's `buildUpstreamURL`.
pub fn build_upstream_url(host: &str, path: &str, params: &[(String, String)]) -> String {
    let base = format!(
        "{}/{}",
        host.trim_end_matches('/'),
        path.trim_start_matches('/')
    );
    if params.is_empty() {
        return base;
    }
    format!("{}?{}", base, encode_query(params))
}

pub fn int_default(raw: &str, def: i64) -> i64 {
    if raw.is_empty() {
        return def;
    }
    raw.parse::<i64>().unwrap_or(def)
}

pub fn default_val(v: &str, def: &str) -> String {
    if v.is_empty() {
        def.to_string()
    } else {
        v.to_string()
    }
}

/// Go's `cleanItemIDs`.
pub fn clean_item_ids(raw: &str) -> String {
    let joined: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
    joined.trim_matches(',').to_string()
}

/// Go's `rawJSON`: parse for pass-through.
pub fn raw_json(raw: &[u8]) -> Result<Value, crate::error::ApiError> {
    serde_json::from_slice(raw)
        .map_err(|e| crate::error::ApiError::Internal(format!("parse upstream json: {e}")))
}

/// Go's `setContentInPlace`.
pub fn set_content_in_place(raw: &[u8], plaintext: &str) -> Result<Value, crate::error::ApiError> {
    let mut v = raw_json(raw)?;
    if let Some(root) = v.as_object_mut() {
        if let Some(data) = root.get_mut("data").and_then(|d| d.as_object_mut()) {
            data.insert("content".to_string(), Value::from(plaintext));
        }
    }
    Ok(v)
}

/// Go's `readMaybeGzip` is handled by the transport.
/// Go's `Dechunk` (raw chunked framing the transport did not de-frame).
pub fn dechunk(data: &[u8]) -> Vec<u8> {
    let nl = match data.iter().position(|b| *b == b'\n') {
        Some(0) | None => return data.to_vec(),
        Some(n) => n,
    };
    let size_line: Vec<u8> = data[..nl]
        .iter()
        .copied()
        .take_while(|b| *b != b'\r')
        .collect();
    if size_line.is_empty() {
        return data.to_vec();
    }
    if !size_line.iter().all(|b| b.is_ascii_hexdigit()) {
        return data.to_vec();
    }

    let mut out: Vec<u8> = Vec::new();
    let mut rest: &[u8] = data;
    while let Some(nl) = rest.iter().position(|b| *b == b'\n') {
        let size_line: Vec<u8> = rest[..nl]
            .iter()
            .copied()
            .take_while(|b| *b != b'\r')
            .collect();
        if size_line.is_empty() {
            break;
        }
        let text = String::from_utf8_lossy(&size_line);
        let size = match usize::from_str_radix(&text, 16) {
            Ok(s) => s,
            Err(_) => break,
        };
        rest = &rest[nl + 1..];
        if size == 0 {
            break;
        }
        let take = size.min(rest.len());
        out.extend_from_slice(&rest[..take]);
        rest = &rest[take..];
        if rest.len() >= 2 && rest[0] == b'\r' && rest[1] == b'\n' {
            rest = &rest[2..];
        } else if !rest.is_empty() && rest[0] == b'\n' {
            rest = &rest[1..];
        }
    }
    if out.is_empty() {
        data.to_vec()
    } else {
        out
    }
}

pub fn user_agent_headers(agent: &str) -> Vec<(String, String)> {
    vec![("User-Agent".to_string(), agent.to_string())]
}
