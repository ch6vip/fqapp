use super::super::*;

#[test]
fn merge_variant_rows_keeps_the_fallback_only_top_tier() {
    // 实测形状（2026-10-12）：主列表到 720P 为止，fallback 列表多一个
    // 1080p。合并后 1080P 必须在列表里，且同档不重复。
    const SPADE: &str = "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw==";
    let primary = json!({
        "video_1": { "main_url": "https://example.test/360.mp4", "vwidth": 360, "vheight": 640,
            "codec_type": "bytevc1", "spade_a": SPADE },
        "video_2": { "main_url": "https://example.test/720.mp4", "vwidth": 720, "vheight": 1280,
            "codec_type": "bytevc1", "spade_a": SPADE }
    });
    let fallback = json!({
        "video_1": { "main_url": "https://example.test/720.mp4", "vwidth": 720, "vheight": 1280,
            "codec_type": "bytevc1", "spade_a": SPADE },
        "video_2": { "main_url": "https://example.test/1080.mp4", "vwidth": 1080, "vheight": 1920,
            "codec_type": "bytevc1", "spade_a": SPADE }
    });
    let mut scored = variant_rows_scored(primary.as_object(), Some(b"AAAA".to_vec()));
    scored.extend(variant_rows_scored(
        fallback.as_object(),
        Some(b"AAAA".to_vec()),
    ));
    let rows = merge_variant_rows(scored);
    let names: Vec<&str> = rows.iter().map(|v| v["name"].as_str().unwrap()).collect();
    assert_eq!(
        names,
        ["1080P", "720P", "360P"],
        "fallback-only tier must be merged in and duplicates collapsed"
    );
    for row in &rows {
        assert_eq!(row["key_hex"].as_str().unwrap().len(), 32);
    }
}

#[test]
fn merge_variant_rows_still_drops_bytevc2_from_the_fallback_list() {
    // fallback 列表里 1080p 常是 bytevc1、低档是 bytevc2（实测 4/6 部剧）。
    // 合并不得把 bytevc2 带进面板。
    const SPADE: &str = "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw==";
    let fallback = json!({
        "video_1": { "main_url": "https://example.test/1080-vvc.mp4", "vwidth": 1080, "vheight": 1920,
            "codec_type": "bytevc2", "spade_a": SPADE },
        "video_2": { "main_url": "https://example.test/1080-hvc1.mp4", "vwidth": 1080, "vheight": 1920,
            "codec_type": "bytevc1", "spade_a": SPADE },
        "video_3": { "main_url": "https://example.test/720-vvc.mp4", "vwidth": 720, "vheight": 1280,
            "codec_type": "bytevc2", "spade_a": SPADE }
    });
    let rows = merge_variant_rows(variant_rows_scored(
        fallback.as_object(),
        Some(b"AAAA".to_vec()),
    ));
    let names: Vec<&str> = rows.iter().map(|v| v["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["1080P"], "bytevc2 rows must never reach the panel");
}
