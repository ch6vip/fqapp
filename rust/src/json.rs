//! Generic JSON helpers mirroring the Go endpoint helpers.
//!
//! `serde_json::Map` is a BTreeMap by default, so re-serialised objects come
//! out with alphabetically sorted keys - the same shape Go's `encoding/json`
//! produces for `map[string]interface{}`.

use serde_json::{Map, Value};

pub fn as_map(v: &Value) -> Option<&Map<String, Value>> {
    v.as_object()
}

pub fn as_map_mut(v: &mut Value) -> Option<&mut Map<String, Value>> {
    v.as_object_mut()
}

pub fn as_array(v: &Value) -> Option<&Vec<Value>> {
    v.as_array()
}

/// Go's `firstMapString`: first usable value across `keys`.
pub fn first_map_string(m: &Map<String, Value>, keys: &[&str]) -> String {
    for key in keys {
        let Some(v) = m.get(*key) else { continue };
        if v.is_null() {
            continue;
        }
        if let Some(s) = v.as_str() {
            let t = s.trim();
            if !t.is_empty() {
                return t.to_string();
            }
            continue;
        }
        if let Some(s) = value_to_string(v) {
            if !s.is_empty() {
                return s;
            }
        }
    }
    String::new()
}

/// Go's `pickStr`: string as-is, integral numbers as decimal text.
pub fn value_to_string(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Some(i.to_string())
            } else if let Some(u) = n.as_u64() {
                Some(u.to_string())
            } else if let Some(f) = n.as_f64() {
                if f != 0.0 {
                    Some((f as i64).to_string())
                } else {
                    None
                }
            } else {
                None
            }
        }
        Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}

/// Go's `webUpstreamFailed` numeric-code check: only numbers count.
pub fn numeric_code(v: &Value) -> Option<f64> {
    v.as_f64()
}

/// Go's `stripHTMLTags`, including the entity replacements.
pub fn strip_html_tags(s: &str) -> String {
    let mut buf = String::new();
    let mut in_tag = false;
    for ch in s.chars() {
        if ch == '<' {
            in_tag = true;
            continue;
        }
        if ch == '>' {
            in_tag = false;
            continue;
        }
        if !in_tag {
            buf.push(ch);
        }
    }
    buf.replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
        .replace(['<', '>'], "")
}

/// Go's `webOK`.
pub fn web_ok(data: Value) -> Value {
    let mut m = Map::new();
    m.insert("code".into(), Value::from(200));
    m.insert("message".into(), Value::from("success"));
    m.insert("data".into(), data);
    Value::Object(m)
}

/// Go's `webErr`.
pub fn web_err(code: i64, msg: &str) -> Value {
    let mut m = Map::new();
    m.insert("code".into(), Value::from(code));
    m.insert("message".into(), Value::from(msg));
    Value::Object(m)
}

/// Go's `extractUpstreamData`.
pub fn extract_upstream_data(result: &Value) -> Value {
    match as_map(result) {
        Some(m) => match m.get("data") {
            Some(d) => d.clone(),
            None => result.clone(),
        },
        None => result.clone(),
    }
}

/// Go's `findEpisodeList` (depth-limited search for a playlist container).
pub fn find_episode_list(value: &Value, depth: usize) -> Vec<Value> {
    if depth > 5 {
        return Vec::new();
    }
    if let Some(m) = as_map(value) {
        for key in ["episodes", "item_data_list", "lists", "item_list"] {
            if let Some(Value::Array(list)) = m.get(key) {
                if !list.is_empty() {
                    return list.clone();
                }
            }
        }
        for nested in m.values() {
            let found = find_episode_list(nested, depth + 1);
            if !found.is_empty() {
                return found;
            }
        }
    }
    if let Some(list) = as_array(value) {
        for item in list {
            if as_map(item).is_some() {
                return list.clone();
            }
        }
    }
    Vec::new()
}
