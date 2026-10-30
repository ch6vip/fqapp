//! Key and URL golden vectors. They are expectations produced by an
//! independent reference implementation, not by this crate.

use super::*;
use serde_json::json;

fn expect_source(resolution: VideoSourceResolution) -> (String, Vec<u8>) {
    match resolution {
        VideoSourceResolution::Found(url, key) => (url, key),
        other => panic!("expected a playable source, got {other:?}"),
    }
}

#[test]
fn derives_the_short_drama_content_key() {
    let key = derive_spade_content_key("kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg==");
    assert_eq!(hex::encode(key), "4990a92de837e29e18031a370ab744e6");
}

#[test]
fn reads_the_episode_vertical_flag() {
    // 官方 `VideoInfo.vertical` 挂在 `data.video_info_list_map` 的每集
    // 条目上（`com.bytedance.rpc.model.VideoInfo`）。
    let vertical = |body: Value| episode_vertical(&serde_json::to_vec(&body).unwrap());
    assert_eq!(
        vertical(json!({
            "data": { "video_info_list_map": {
                "1004": [{ "vertical": true, "video_model": "{}" }]
            } }
        })),
        Some(true)
    );
    assert_eq!(
        vertical(json!({
            "data": { "video_info_list_map": {
                "1004": [{ "vertical": false }]
            } }
        })),
        Some(false)
    );
    // 缺字段 = None：客户端保持旧行为，不是「默认不竖屏」的猜测。
    assert_eq!(
        vertical(json!({
            "data": { "video_info_list_map": {
                "1004": [{ "video_model": "{}" }]
            } }
        })),
        None
    );
    assert_eq!(vertical(json!({ "data": {} })), None);
    // 上游可能给 0/1 或字符串。
    assert_eq!(
        vertical(json!({
            "data": { "video_info_list_map": { "1004": [{ "vertical": 1 }] } }
        })),
        Some(true)
    );
    // shortplay 形状：VideoInfo 在 `data.<vid>` 上，与 video_model 并列。
    assert_eq!(
        vertical(json!({
            "data": { "vid1": { "video_model": "{}", "vertical": true } }
        })),
        Some(true)
    );
}

#[test]
fn reads_the_embedded_video_model_string() {
    let raw = serde_json::to_vec(&json!({
        "data": { "vid1": { "video_model":
            r#"{"video_list":[{"main_url":"https://example.test/low.mp4"},{"main_url":"https://example.test/high.mp4"}]}"#
        } }
    }))
    .unwrap();
    assert_eq!(
        expect_source(extract_video_url(&raw)).0,
        "https://example.test/high.mp4"
    );
}

#[test]
fn reads_the_shortplay_shape_and_its_key() {
    let model = json!({
        "key_seed": "e/sKbv4roNA/4Xm/6oFbFjBm6AIBteh9Z0EddXTl7yI=",
        "video_list": {
            "video_1": {
                "definition": "360p",
                "main_url": base64::engine::general_purpose::STANDARD
                    .encode("https://v26-reading-video.fqnovelvod.com/example.mp4"),
                "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw=="
            }
        }
    });
    let map = model.as_object().unwrap();
    let (url, key) = expect_source(extract_shortplay_video_model_source(map));
    assert_eq!(url, "https://v26-reading-video.fqnovelvod.com/example.mp4");
    assert_eq!(key.len(), 16);
}

#[test]
fn fallback_source_prefers_the_highest_quality_and_keeps_its_key() {
    let root = json!({
        "video_info": { "data": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": {
                    "main_url": "https://example.test/low.mp4",
                    "vwidth": 720, "vheight": 1280
                },
                "video_5": {
                    "main_url": "https://example.test/high.mp4",
                    "vwidth": 1080, "vheight": 1920,
                    "spade_a": "kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg=="
                }
            }
        } }
    });
    let map = root.as_object().unwrap();
    let (url, key) = expect_source(extract_fallback_video_source(map));
    assert_eq!(url, "https://example.test/high.mp4");
    assert_eq!(hex::encode(key), "4990a92de837e29e18031a370ab744e6");
}

#[test]
fn fallback_source_skips_bytevc2_even_when_it_scores_highest() {
    let root = json!({
        "video_info": { "data": {
            "key_seed": "AAAA",
            "video_list": {
                "video_5": {
                    "main_url": "https://example.test/vvc.mp4",
                    "vwidth": 1080, "vheight": 1920,
                    "codec_type": "bytevc2"
                },
                "video_1": {
                    "main_url": "https://example.test/h264.mp4",
                    "vwidth": 720, "vheight": 1280,
                    "codec_type": "h264"
                }
            }
        } }
    });
    let map = root.as_object().unwrap();
    let (url, _) = expect_source(extract_fallback_video_source(map));
    assert_eq!(url, "https://example.test/h264.mp4");
}

#[test]
fn fallback_source_never_serves_a_bytevc2_only_list() {
    let root = json!({
        "video_info": { "data": {
            "key_seed": "AAAA",
            "video_list": {
                "video_5": {
                    "main_url": "https://example.test/vvc.mp4",
                    "vwidth": 1080, "vheight": 1920,
                    "gear_des_key": "bytevc2_1080p"
                }
            }
        } }
    });
    let map = root.as_object().unwrap();
    assert_eq!(
        extract_fallback_video_source(map),
        VideoSourceResolution::CodecRejected
    );
}

#[test]
fn variant_display_name_follows_the_short_edge_mapping() {
    assert_eq!(variant_display_name(360), "360P");
    assert_eq!(variant_display_name(480), "480P");
    assert_eq!(variant_display_name(540), "540P");
    assert_eq!(variant_display_name(720), "720P");
    assert_eq!(variant_display_name(1080), "1080P");
    assert_eq!(variant_display_name(1440), "2K");
    assert_eq!(variant_display_name(2160), "4K");
    assert_eq!(variant_display_name(0), "");
}

#[test]
fn variant_rows_skip_bytevc2_and_sort_by_the_short_edge() {
    // 竖屏漫剧（series 7686494169098898456 实测形状）：video_list 是
    // object，vheight 是长边——档位名必须取短边，bytevc2 档被排除。
    let video_list = json!({
        "video_4": {
            "main_url": "https://example.test/a.mp4",
            "vwidth": 720, "vheight": 1280, "codec_type": "bytevc2"
        },
        "video_3": {
            "main_url": "https://example.test/720.mp4",
            "vwidth": 720, "vheight": 1280, "codec_type": "h264",
            "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw=="
        },
        "video_2": {
            "main_url": "https://example.test/540.mp4",
            "vwidth": 540, "vheight": 960, "codec_type": "h264",
            "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw=="
        },
        "video_1": {
            "main_url": "https://example.test/360.mp4",
            "vwidth": 360, "vheight": 640, "codec_type": "h264",
            "spade_a": "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw=="
        }
    });
    let rows = merge_variant_rows(variant_rows_scored(
        video_list.as_object(),
        Some(b"AAAA".to_vec()),
    ));
    let names: Vec<&str> = rows.iter().map(|v| v["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["720P", "540P", "360P"]);
    for row in &rows {
        assert!(row["url"].as_str().unwrap().starts_with("https://"));
        assert_eq!(row["key_hex"].as_str().unwrap().len(), 32);
    }
}

#[test]
fn fallback_source_prefers_h264_on_equal_quality() {
    let root = json!({
        "video_info": { "data": {
            "key_seed": "AAAA",
            "video_list": {
                "video_1": {
                    "main_url": "https://example.test/h265.mp4",
                    "vwidth": 1080, "vheight": 1920,
                    "bitrate": 2000000,
                    "codec_type": "h265"
                },
                "video_2": {
                    "main_url": "https://example.test/h264.mp4",
                    "vwidth": 1080, "vheight": 1920,
                    "bitrate": 2000000,
                    "codec_type": "h264"
                }
            }
        } }
    });
    let map = root.as_object().unwrap();
    let (url, _) = expect_source(extract_fallback_video_source(map));
    assert_eq!(url, "https://example.test/h264.mp4");
}
