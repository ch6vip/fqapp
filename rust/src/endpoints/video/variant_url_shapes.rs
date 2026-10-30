//! `main_url` 有两种形态，混淆它们会让 fallback 列表（含 1080p）整片解不出来。
//! 实例见 .agents/notes/implemented/bug-fix/2026-10-12-short-drama-1080p-variant-merge.md

use super::*;
use serde_json::json;

fn entry(main_url: String) -> Map<String, Value> {
    json!({
        "main_url": main_url,
        "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw==",
    })
    .as_object()
    .unwrap()
    .clone()
}

#[test]
fn spade_encrypted_main_url_reaches_the_decryptor_intact() {
    // spade 密文：base64 解出来以 a8 00 01 00 开头。旧实现无条件先解一层
    // base64 再交给 decrypt_spade_url，密文被毁成不可再解的字节串——面板
    // 会拿到一个不是 URL 的垃圾串（实测就是 1080P 那一档）。
    let mut blob = vec![0xa8u8, 0x00, 0x01, 0x00];
    blob.extend(0u8..32);
    let main_url = base64::engine::general_purpose::STANDARD.encode(&blob);
    let seed = b"AAAA".to_vec();

    let (url, _) = decrypt_variant_entry(&entry(main_url.clone()), Some(&seed)).unwrap();
    assert_eq!(
        url,
        decrypt_spade_url(&main_url, &seed),
        "spade ciphertext must not be pre-decoded before decrypt_spade_url"
    );
}

#[test]
fn base64_wrapped_plain_url_still_decodes() {
    // 明文地址：base64 解出来直接以 http 开头，必须照旧解出来。
    let main_url =
        base64::engine::general_purpose::STANDARD.encode(b"https://example.test/1080.mp4");
    let (url, key) = decrypt_variant_entry(&entry(main_url), Some(b"AAAA")).unwrap();
    assert_eq!(url, "https://example.test/1080.mp4");
    assert_eq!(key.len(), 16);
}
