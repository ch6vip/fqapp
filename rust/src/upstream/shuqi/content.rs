//! 正文解码与免签 CDN JSONP 解析。

use std::sync::OnceLock;

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;

/// 标准 ROT13（源脚本的 `sqRot` 是它的等价变体）。
pub fn rot13(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            'a'..='z' => (((c as u8 - b'a' + 13) % 26) + b'a') as char,
            'A'..='Z' => (((c as u8 - b'A' + 13) % 26) + b'A') as char,
            other => other,
        })
        .collect()
}

fn br_regex() -> &'static regex::Regex {
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    RE.get_or_init(|| regex::Regex::new(r"(?i)<br\s*/?>").expect("br regex"))
}

/// 正文腿的解码：ROT13 → base64 → `<br>` 转换行。任何一步失败都退回上一步的结果。
pub fn decode_content(s: &str) -> String {
    let rotated = rot13(s);
    let cleaned: String = rotated.chars().filter(|c| !c.is_whitespace()).collect();
    let bytes = match STANDARD.decode(cleaned.as_bytes()) {
        Ok(b) => b,
        Err(_) => rotated.into_bytes(),
    };
    let text = String::from_utf8_lossy(&bytes).into_owned();
    br_regex().replace_all(&text, "\n").into_owned()
}

/// 剥离标签并做实体还原（`sqStripTags` + `&nbsp;`）。
pub fn strip_tags(s: &str) -> String {
    static RE: OnceLock<regex::Regex> = OnceLock::new();
    let re = RE.get_or_init(|| regex::Regex::new(r"<[^>]+>").expect("tag regex"));
    re.replace_all(s, "")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 免签 CDN 的 JSONP 响应体解析：剥壳 → `arr[0].content` → 去标签。
///
/// 返回 `None` 表示这一腿没取到可用正文（调用方继续枚举下一个 host/flag）。
pub fn parse_cdn_payload(body: &str) -> Option<String> {
    let mut inner = body;
    if let Some(i) = body.find('(') {
        if i > 0 {
            inner = &body[i + 1..];
            if let Some(j) = inner.rfind(')') {
                inner = &inner[..j];
            }
        }
    }
    let arr: serde_json::Value = serde_json::from_str(inner).ok()?;
    let content = arr.get(0)?.get("content")?.as_str()?.to_string();
    let text = br_regex()
        .replace_all(&content, "\n")
        .into_owned()
        .replace("&nbsp;", " ");
    let text = strip_tags(&text);
    if text.trim().is_empty() {
        None
    } else {
        Some(text)
    }
}
