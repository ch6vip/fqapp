//! 协议层单测：keystream、签名、公参键序与正文解码。

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;

use super::content::{decode_content, parse_cdn_payload, rot13};
use super::crypto::{enc18, keystream, public_str, sign, xor_base64, SKEY};
use super::params::{Device, APP_USER_ID};
use super::request::{app_body, app_body_with_device};

#[test]
fn keystream_decodes_to_2048_binary_bytes() {
    let ks = keystream();
    assert_eq!(ks.len(), 2048, "keystream must be 2048 bytes");
    assert_eq!(
        &ks[..16],
        &[
            0x40, 0x0c, 0x27, 0xcc, 0xcf, 0x65, 0x68, 0xbc, 0xd2, 0xb7, 0x19, 0x37, 0x8e, 0x53,
            0xcb, 0xe7
        ],
        "binary decode, not text decode"
    );
}

#[test]
fn enc18_takes_five_tail_digits_then_timestamp() {
    // ts[1]=7 ts[3]=5 ts[5]=0 ts[8]=0 ts[6]=0 -> key 75000
    let enc = enc18("8158804976", "1755900000000");
    assert_eq!(enc.len(), 18);
    assert!(enc.ends_with("1755900000000"));
    assert_eq!(&enc[..5], "00000");
}

#[test]
fn enc18_pads_short_timestamp_and_handles_zero_uid() {
    let enc = enc18("0", "17559");
    assert_eq!(enc.len(), 18);
    // 0 uid -> 24697；13 位补 '2' 前缀
    assert!(enc.ends_with("2222217559000") || enc.ends_with("2222217559"));
}

#[test]
fn rot13_matches_standard_rot13() {
    assert_eq!(rot13("abc"), "nop");
    assert_eq!(rot13("Nop"), "Abc");
    assert_eq!(rot13("Zm9v"), "Mz9i");
}

#[test]
fn public_str_is_ordered_and_ends_with_ampersand() {
    let dev = Device::default();
    let s = public_str(APP_USER_ID, "1755900000000", "200001755900000000", &dev);
    assert!(s.ends_with('&'));
    assert!(s.contains("platform=2&"));
    assert!(!s.contains("timestamp="));
    assert!(s.contains("enc=200001755900000000&"));
    // 键序固定：soft_id 在 user_id 之前，userId 在 ver 之前。
    let soft = s.find("soft_id=").unwrap();
    let user = s.find("user_id=").unwrap();
    let user_id_camel = s.find("userId=").unwrap();
    let ver = s.find("ver=").unwrap();
    assert!(soft < user && user < user_id_camel && user_id_camel < ver);
}

#[test]
fn sign_is_stable_lowercase_md5_and_ignores_blacklist() {
    let pairs = vec![
        ("bookId".to_string(), "34078".to_string()),
        ("sign".to_string(), "should-be-ignored".to_string()),
        ("key".to_string(), "should-be-ignored".to_string()),
        ("platform".to_string(), "an".to_string()),
    ];
    let a = sign(&pairs, SKEY);
    let b = sign(&pairs, SKEY);
    assert_eq!(a, b);
    assert_eq!(a.len(), 32);
    assert!(a
        .chars()
        .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    // 黑名单键不能影响结果。
    let noisy = vec![
        ("bookId".to_string(), "34078".to_string()),
        ("platform".to_string(), "an".to_string()),
    ];
    assert_eq!(a, sign(&noisy, SKEY));
}

#[test]
fn sign_sorts_keys_lexicographically() {
    let a = sign(
        &[
            ("b".to_string(), "2".to_string()),
            ("a".to_string(), "1".to_string()),
        ],
        SKEY,
    );
    let b = sign(
        &[
            ("a".to_string(), "1".to_string()),
            ("b".to_string(), "2".to_string()),
        ],
        SKEY,
    );
    assert_eq!(a, b);
}

#[test]
fn xor_roundtrip_uses_each_message_from_offset_zero() {
    let ks = keystream();
    let plain = b"hello shuqi";
    let cipher = xor_base64(plain).unwrap();
    let bytes = STANDARD.decode(cipher.as_bytes()).unwrap();
    let back: Vec<u8> = bytes.iter().zip(ks.iter()).map(|(c, k)| c ^ k).collect();
    assert_eq!(back, plain);
}

#[test]
fn xor_rejects_plaintext_longer_than_keystream() {
    let long = vec![b'a'; 2049];
    assert!(xor_base64(&long).is_err());
}

#[test]
fn public_str_matches_source_comment_length() {
    // 源文件注释记的是「x-sq-public 明文 461 字节」，对应设备字段全空。
    let dev = Device::default();
    let s = public_str(APP_USER_ID, "1755900000000", "000001755900000000", &dev);
    assert_eq!(s.len(), 461);
}

/// 黄金向量：由原始 JS 函数算出（Node 补齐 `native.*`、设备身份固定）。
///
/// 这条测试锁死三件事：`enc` 的位数、`sign` 的拼接与排序、`x-sq-public`
/// 的键序与编码。三者任何一处偏移都会让向量对不上。
#[test]
fn app_body_matches_js_reference_vector() {
    let dev = Device {
        sq_uniq_device_id: "AAAAAAAAAAAAAAAAAAAAAA".to_string(),
        utdid: "BBBBBBBBBBBBBBBBBBBBBBBBBBBB".to_string(),
        sn: "0011223344556677".to_string(),
        umidtoken: "00112233445566778899aabbccddeeff00112233".to_string(),
        otdd: "CCCCCCCCCCCCCCCCCCCCCC".to_string(),
    };
    let ts = "1755900000000";
    let req = app_body_with_device(&[("bookId", "34078")], None, Some(ts), &dev).unwrap();

    let encoded = req.body.strip_prefix("data=").expect("form body");
    let decoded = percent_encoding::percent_decode_str(encoded)
        .decode_utf8()
        .expect("percent decode");
    let cipher = STANDARD.decode(decoded.as_bytes()).expect("base64");
    let plain: Vec<u8> = cipher
        .iter()
        .zip(keystream().iter())
        .map(|(c, k)| c ^ k)
        .collect();
    let payload: serde_json::Value = serde_json::from_slice(&plain).expect("json");

    assert_eq!(payload["enc"], "000001755900000000");
    assert_eq!(payload["sign"], "9f379316f46599dcaa0cc3ec8330a3cb");
    assert_eq!(payload["key"], "sq_app_gateway");
    // 体内是 "an"，public 串里是 "2"。
    assert_eq!(payload["platform"], "an");

    let public_plain = public_str(APP_USER_ID, ts, "000001755900000000", &dev);
    assert_eq!(public_plain.len(), 589);
    assert!(public_plain.starts_with("soft_id=1&user_id=8158804976&userId=8158804976&ver=261013&"));
    assert!(public_plain.contains("&msv=3&enc=000001755900000000&vc=5d73&"));
    assert!(public_plain.ends_with("&otdd=CCCCCCCCCCCCCCCCCCCCCC&"));

    let header = req
        .headers
        .iter()
        .find(|(k, _)| k == "x-sq-public")
        .expect("public header");
    let expected: Vec<u8> = public_plain
        .as_bytes()
        .iter()
        .zip(keystream().iter())
        .map(|(p, k)| p ^ k)
        .collect();
    assert_eq!(header.1, STANDARD.encode(expected));
}

#[test]
fn app_body_carries_nine_headers_and_form_body() {
    let req = app_body(&[("bookId", "34078")], None, Some("1755900000000")).unwrap();
    assert!(req.body.starts_with("data="));
    assert_eq!(req.headers.len(), 9);
    let names: Vec<&str> = req.headers.iter().map(|(k, _)| k.as_str()).collect();
    for want in [
        "content-type",
        "user-agent",
        "x-sq-req-platform",
        "x-sq-s-key",
        "x-sq-sv",
        "x-sq-public",
        "x-sq-req-encrypt",
        "x-sq-req-encrypt-param",
        "x-sq-api-encrypt",
    ] {
        assert!(names.contains(&want), "missing header {want}");
    }
}

#[test]
fn decode_content_roundtrips_rot13_then_base64() {
    // "hello" 经 ROT13 -> "uryyb"，再 base64
    let encoded = STANDARD.encode(b"hello world");
    let rotated = rot13(&encoded);
    assert_eq!(decode_content(&rotated), "hello world");
}

#[test]
fn decode_content_converts_br_tags() {
    let encoded = STANDARD.encode(b"a<br>b<br/>c<BR />d");
    assert_eq!(decode_content(&rot13(&encoded)), "a\nb\nc\nd");
}

#[test]
fn cdn_payload_strips_jsonp_and_tags() {
    // 源脚本语义：取第一个 '(' 之后，到最后一个 ')' 之前
    let payload = r#"cb([{"content":"line1<br/>line2&nbsp;x"}])"#;
    assert_eq!(parse_cdn_payload(payload).unwrap(), "line1\nline2 x");
    // 无 JSONP 包装的裸数组同样可解析
    assert_eq!(
        parse_cdn_payload(r#"[{"content":"plain"}]"#).unwrap(),
        "plain"
    );
    assert!(parse_cdn_payload(r#"[{"content":"   "}]"#).is_none());
}
