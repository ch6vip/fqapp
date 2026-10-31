//! keystream、签名、`enc` 与 `x-sq-public` 构造。

use std::sync::OnceLock;

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use md5::{Digest, Md5};
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};

use super::params::{Device, PUB_ORDER, PUB_PARAMS};

/// 明文签名盐（源自源文件 `js` 第 12 行，客户端硬编码常量）。
pub(super) const SKEY: &str = "467694bd8912441cae8498b3c7e4282c";
/// 参与签名的 `sqSv` 值。
pub(super) const SQ_SV: &str = "1.0";

/// 签名剔除项，与 App 的 `CommonSignUtils` 一致（注意大写 `X`）。
const NO_SIGN: &[&str] = &[
    "sign",
    "key",
    "_public",
    "_reqid",
    "_beta",
    "_",
    "X",
    "XNEBULAXMLHTTPREQUEST",
    "callbackUrl",
];

/// JS `encodeURIComponent` 保留集：`A-Za-z0-9 - _ . ! ~ * ' ( )`。
const URI_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'!')
    .remove(b'~')
    .remove(b'*')
    .remove(b'\'')
    .remove(b'(')
    .remove(b')');

/// 2048 字节 keystream（base64）。必须二进制解码。
const KS_B64: &str = "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";

/// 二进制 keystream，恰好 2048 字节。
pub fn keystream() -> &'static [u8] {
    static KS: OnceLock<Vec<u8>> = OnceLock::new();
    KS.get_or_init(|| STANDARD.decode(KS_B64.as_bytes()).unwrap_or_default())
}

/// 当前毫秒时间戳（13 位十进制字符串）。
pub fn now_ms() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .to_string()
}

/// JS `encodeURIComponent` 等价实现。
///
/// 已知不确定性：源脚本调用的是宿主 `native.urlencode`，其精确字符集无法从
/// 文件推断。`!'()` 四个字符是 `encodeURIComponent` 与 RFC1738 的唯一分歧点，
/// 现有公参取值不含这四个字符，所以此处按 `encodeURIComponent` 实现。
pub(super) fn uri_encode(s: &str) -> String {
    utf8_percent_encode(s, URI_SET).to_string()
}

/// `x-sq-public` 用的编码：在 [`uri_encode`] 基础上再对齐三条修正。
fn public_enc(s: &str) -> String {
    uri_encode(s)
        .replace('+', "%20")
        .replace('*', "%2A")
        .replace("%7E", "~")
}

/// 明文签名：剔除黑名单 → 补 `sqSv` → 按键名升序拼 `k=enc(v)&` → 末尾接盐取 md5。
pub fn sign(pairs: &[(String, String)], skey: &str) -> String {
    let mut items: Vec<(String, String)> = pairs
        .iter()
        .filter(|(k, _)| !NO_SIGN.iter().any(|n| n == k))
        .cloned()
        .collect();
    if !items.iter().any(|(k, _)| k == "sqSv") {
        items.push(("sqSv".to_string(), SQ_SV.to_string()));
    }
    // 键名全为 ASCII，`str::cmp`（字节序）与 JS 的 UTF-16 code unit 序一致。
    items.sort_by(|a, b| a.0.cmp(&b.0));
    let mut raw = String::new();
    for (k, v) in &items {
        raw.push_str(k);
        raw.push('=');
        raw.push_str(&uri_encode(v));
        raw.push('&');
    }
    raw.push_str("skey=");
    raw.push_str(skey);
    md5_hex(&raw)
}

/// md5 小写 hex。
pub fn md5_hex(s: &str) -> String {
    let mut hasher = Md5::new();
    hasher.update(s.as_bytes());
    hex::encode(hasher.finalize())
}

/// `enc` 参数：时间戳取 `[1][3][5][8][6]` 当 key，`key*uid` 取末 5 位再拼 13 位时间戳。
pub fn enc18(uid: &str, ts: &str) -> String {
    let mut ts = ts.to_string();
    while ts.chars().count() < 13 {
        ts.insert(0, '2');
    }
    if ts.chars().count() > 13 {
        ts = ts.chars().take(13).collect();
    }
    let uid_n: u64 = uid.parse().unwrap_or(0);
    let uid_n = if uid_n == 0 { 24_697 } else { uid_n };
    let digits: Vec<char> = ts.chars().collect();
    let key_s: String = [1usize, 3, 5, 8, 6]
        .iter()
        .map(|&i| digits.get(i).copied().unwrap_or('0'))
        .collect();
    let key: u64 = key_s.parse().unwrap_or(0);
    let product = if key == 0 {
        12_347u64.saturating_mul(uid_n)
    } else {
        key.saturating_mul(uid_n)
    };
    let product = product.to_string();
    let tail: String = product
        .chars()
        .skip(product.chars().count().saturating_sub(5))
        .collect();
    format!("{tail}{ts}")
}

/// `x-sq-public` 明文：公参 + 设备身份 + 身份覆盖，按 [`PUB_ORDER`] 拼 `k=enc(v)&`。
pub fn public_str(uid: &str, ts: &str, enc: &str, dev: &Device) -> String {
    let mut m: std::collections::HashMap<&str, String> = PUB_PARAMS
        .iter()
        .map(|(k, v)| (*k, (*v).to_string()))
        .collect();
    for (k, v) in dev.pairs() {
        m.insert(k, v);
    }
    m.insert("user_id", uid.to_string());
    m.insert("userId", uid.to_string());
    // 注意：这里是 "2"，请求体里是 "an"。
    m.insert("platform", "2".to_string());
    m.insert("enc", enc.to_string());
    // 源脚本也赋了 timestamp，但 PUB_ORDER 不含它，所以不会输出。
    let _ = ts;

    let mut out = String::new();
    for k in PUB_ORDER {
        if let Some(v) = m.get(k) {
            out.push_str(k);
            out.push('=');
            out.push_str(&public_enc(v));
            out.push('&');
        }
    }
    out
}

/// 明文 XOR keystream 后 base64。明文不能超过 keystream 长度。
pub(super) fn xor_base64(plain: &[u8]) -> Result<String, String> {
    let ks = keystream();
    if ks.is_empty() {
        return Err("shuqi keystream failed to decode".to_string());
    }
    if plain.len() > ks.len() {
        return Err(format!(
            "shuqi keystream too short: plaintext {} > {}",
            plain.len(),
            ks.len()
        ));
    }
    let out: Vec<u8> = plain.iter().zip(ks.iter()).map(|(p, k)| p ^ k).collect();
    Ok(STANDARD.encode(out))
}
