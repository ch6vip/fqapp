//! Exercise codec rejection through the real dispatcher, including the raw
//! response and download fallbacks that extractor-only tests cannot cover.

mod common;

use common::{build_server, pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use serde_json::{json, Value};

const ALLOWED_URL: &str = "https://example.invalid/h264.mp4";
const REJECTED_URL: &str = "https://example.invalid/bytevc2.mp4";
const SPADE_A: &str = "kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg==";
const KEY_HEX: &str = "4990a92de837e29e18031a370ab744e6";

fn response_shapes(variants: Vec<Value>) -> Vec<(&'static str, Value)> {
    let video_map: serde_json::Map<String, Value> = variants
        .iter()
        .enumerate()
        .map(|(i, v)| (format!("video_{i}"), v.clone()))
        .collect();
    let shortplay = json!({"key_seed": "AAAA", "video_list": video_map});
    let array_model = json!({"video_list": variants});
    vec![
        (
            "shortplay object",
            json!({"data": {"video_model": shortplay}}),
        ),
        (
            "shortplay string",
            json!({"data": {"video_model": shortplay.to_string()}}),
        ),
        (
            "nested shortplay",
            json!({"data": {"episode": {"video_model": shortplay}}}),
        ),
        (
            "array object",
            json!({"data": {"video_model": array_model}}),
        ),
        (
            "nested array string",
            json!({"data": {"episode": {"video_model": array_model.to_string()}}}),
        ),
        (
            "phoenix play info",
            json!({"data": {"video_info_list_map": {"episode": [
                {"play_info_list": variants}
            ]}}}),
        ),
    ]
}

async fn request_video(server: &Server, query: &str) -> (u16, Value) {
    let response = dispatch(
        server,
        &Request {
            method: "GET".to_string(),
            path: "/api/v1/videos/episode".to_string(),
            query: query.to_string(),
            ..Default::default()
        },
    )
    .await;
    let status = response.status;
    let body = response.into_bytes().await.expect("response body");
    (
        status,
        serde_json::from_slice(&body).expect("JSON response"),
    )
}

fn assert_rejected(status: u16, body: &Value, context: &str) {
    assert_eq!(status, 500, "{context}: {body}");
    assert_eq!(body["success"], false, "{context}: {body}");
    assert_eq!(body["error"], "该视频暂不支持播放", "{context}: {body}");
    assert!(!body.to_string().contains("https://"), "{context}: {body}");
}

#[tokio::test]
async fn bytevc2_only_is_terminal_across_response_shapes_and_modes() {
    for codec in [
        json!({"codec_type": "ByTeVc2"}),
        json!({"video_meta": {"codec_type": "BYTEVC2"}}),
        json!({"gear_des_key": "bytevc2_1080p"}),
    ] {
        let mut variant = codec;
        variant["main_url"] = json!(REJECTED_URL);
        for (name, payload) in response_shapes(vec![variant]) {
            let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
            let dir = TempDir::new("video-codec-reject");
            let server =
                build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
            for mode in ["mode=stream", ""] {
                let (status, body) = request_video(&server, mode).await;
                assert_rejected(status, &body, &format!("{name}, {mode}"));
            }
            assert!(upstream
                .requests()
                .iter()
                .all(|r| !r.path.ends_with(".mp4")));
        }
    }
}

#[tokio::test]
async fn missing_or_invalid_seed_cannot_hide_codec_rejection() {
    for seed in [Value::Null, json!(""), json!("invalid!")] {
        let payload = json!({"data": {"video_model": {
            "key_seed": seed,
            "video_list": {"video_1": {
                "codec_type": "bytevc2", "main_url": REJECTED_URL
            }}
        }}});
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-seed");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_rejected(status, &body, "invalid seed");
    }
}

#[tokio::test]
async fn mixed_variants_keep_h264_preference_across_response_shapes() {
    // Put H.264 first: blindly taking the last array entry would pick bytevc2,
    // and filtering without ranking would pick H.265 at the same quality.
    let variants = vec![
        json!({"main_url": ALLOWED_URL, "codec_type": "h264", "vwidth": 720}),
        json!({"main_url": "https://example.invalid/h265.mp4", "codec_type": "h265", "vwidth": 720}),
        json!({"main_url": REJECTED_URL, "codec_type": "bytevc2", "vwidth": 1080}),
    ];
    for (name, payload) in response_shapes(variants) {
        let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
        let dir = TempDir::new("video-codec-mixed");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        let (status, body) = request_video(&server, "mode=stream").await;
        assert_eq!(status, 200, "{name}: {body}");
        assert_eq!(body["video_url"], ALLOWED_URL, "{name}: {body}");
        assert!(!body.to_string().contains(REJECTED_URL), "{name}: {body}");
    }
}

#[tokio::test]
async fn unrecognized_payload_keeps_legacy_raw_response_compatibility() {
    let payload = json!({"code": 0, "data": {"legacy": {"main_url": ALLOWED_URL}}});
    let expected = payload.clone();
    let upstream = MockUpstream::start(move |_| MockReply::json(payload.clone())).await;
    let dir = TempDir::new("video-codec-legacy");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    for mode in ["mode=stream", ""] {
        let (status, body) = request_video(&server, mode).await;
        assert_eq!(status, 200);
        assert_eq!(body, expected);
    }
}

#[tokio::test]
async fn fallback_rejection_cannot_return_the_original_model_url() {
    let model = json!({
        "fallback_api": "https://example.invalid/fallback",
        "video_list": [{
            "main_url": "https://example.invalid/original.mp4",
            "encrypt_info": {"encrypt": true}
        }]
    });
    for data in [
        json!({"video_model": model}),
        json!({"episode": {"video_model": model.to_string()}}),
    ] {
        let upstream = MockUpstream::start(move |req| {
            if req.path == "/fallback" {
                return MockReply::json(json!({"video_info": {"data": {
                    "key_seed": "AAAA", "video_list": {"video_1": {
                        "main_url": REJECTED_URL, "codec_type": "bytevc2"
                    }}
                }}}));
            }
            MockReply::json(json!({"data": data}))
        })
        .await;
        let dir = TempDir::new("video-codec-fallback");
        let server =
            build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
        for mode in ["mode=stream", ""] {
            let (status, body) = request_video(&server, mode).await;
            assert_rejected(status, &body, "fallback rejected");
        }
        let requests = upstream.requests();
        assert!(requests.iter().any(|r| r.path == "/fallback"));
        assert!(requests.iter().all(|r| !r.path.ends_with(".mp4")));
    }
}

#[tokio::test]
async fn download_failure_returns_only_the_selected_url_and_its_key() {
    let upstream = MockUpstream::start(|req| {
        if req.path.ends_with(".mp4") {
            return MockReply::status(500);
        }
        MockReply::json(json!({"data": {"video_model": {
            "key_seed": "AAAA", "video_list": {
                "video_1": {"main_url": ALLOWED_URL, "codec_type": "h264", "spade_a": SPADE_A},
                "video_2": {"main_url": REJECTED_URL, "codec_type": "bytevc2"}
            }
        }}}))
    })
    .await;
    let dir = TempDir::new("video-codec-download");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "").await;
    assert_eq!(status, 200);
    assert_eq!(body["video_url"], ALLOWED_URL);
    assert_eq!(body["key_hex"], KEY_HEX);
    assert!(!body.to_string().contains(REJECTED_URL));
    let requests = upstream.requests();
    assert!(requests.iter().any(|r| r.path == "/h264.mp4"));
    assert!(requests.iter().all(|r| r.path != "/bytevc2.mp4"));
}

#[tokio::test]
async fn successful_download_keeps_the_local_source_contract() {
    let upstream = MockUpstream::start(|req| {
        if req.path == "/h264.mp4" {
            return MockReply {
                status: 200,
                headers: vec![],
                body: b"video fixture".to_vec(),
            };
        }
        MockReply::json(json!({"data": {"episode": {"video_model": {
            "video_list": [{"main_url": ALLOWED_URL, "codec_type": "h264"}]
        }}}}))
    })
    .await;
    let dir = TempDir::new("video-codec-local");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    let (status, body) = request_video(&server, "").await;
    assert_eq!(status, 200);
    assert_eq!(body["video_url"], "/src/episode.mp4");
    assert_eq!(
        body["video_info"]["data"]["video_list"]["video_1"]["main_url"],
        "/src/episode.mp4"
    );
    assert_eq!(
        std::fs::read(dir.join("src/episode.mp4")).unwrap(),
        b"video fixture"
    );
}
