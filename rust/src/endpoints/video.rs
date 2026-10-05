//! Video endpoints: the multi-quality video resolver plus the short-drama
//! series detail and episode-list endpoints.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use base64::Engine;
use futures::future::BoxFuture;
use once_cell::sync::Lazy;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha512};

use crate::endpoints::base::{
    dragon_read_json_headers, phoenix_player_headers, phoenix_player_url, Upstream, UpstreamMode,
    UpstreamRequestSpec, UA_ANDROID_BROWSER, UA_WINDOWS_BROWSER,
};
use crate::endpoints::util::{default_val, go_query_escape, int_default, user_agent_headers};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};
use crate::upstream::UpstreamRequest;

/// The spade derivation constant table from video.go.
const SPADE_CONSTANTS: [u8; 64] = [
    77, 212, 194, 230, 184, 49, 98, 9, 14, 82, 179, 199, 166, 115, 59, 164, 28, 178, 70, 43, 130,
    154, 181, 138, 25, 107, 57, 219, 87, 23, 117, 36, 244, 155, 175, 127, 8, 232, 214, 141, 38,
    167, 46, 55, 193, 169, 90, 47, 31, 5, 165, 24, 146, 174, 242, 148, 151, 50, 182, 42, 56, 170,
    221, 88,
];

const FALLBACK_USER_AGENT: &str = "com.xs.fm/632 (Linux; U; Android 15; zh_CN; 23049RAD8C; Build/AQ3A.250226.002; Cronet/TTNetVersion:fc4cebd3 2024-12-10 QuicVersion:d9628e3d 2024-10-11)";

/// The shortplay video_model URL from fetchShortplayVideoModel.
const SHORTPLAY_VIDEO_MODEL_URL: &str = "https://api3-normal-sinfonlinea.fqnovel.com/novel/player/video_model/v1/?iid={install_id}&device_id={device_id}&aid=1967&app_name=novelapp&version_code=72132&version_name=7.2.1.32&device_platform=android&device_brand=Xiaomi&os_version=13&cdid=75e2081b-d8bf-4767-91e8-3424546b4d2e";

/// Reading directory endpoint, copied from directory.go so pseries can fall
/// back to it (the Rust directory endpoint is not wired into this crate yet).
const DIRECTORY_READING_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/directory/all_items/v?";
const DIRECTORY_READING_QUERY_SUFFIX: &str = "&book_info_md5=&need_version=true&device_id={device_id}&ac=wifi&channel=xiaomi_1967_64&aid=1967&app_name=novelapp&version_code=65132&version_name=6.5.1.32&device_platform=android&os=android&ssmix=a&device_type=FRD-AL10&device_brand=honor&language=zh&os_api=28&os_version=9&manifest_version_code=65132&resolution=1080*1920&dpi=480&update_version_code=65132&pv_player=65132&=&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&host_abi=arm64-v8a&dragon_device_type=phone&rom_version=FRD-AL10+8.0.0.556%28C00%29&compliance_status=0";

const VIDEO_DETAIL_PATH: &str = "/novel/player/video_detail/v1/";

static VIDEO_CACHE_LOCK: Lazy<tokio::sync::Mutex<()>> = Lazy::new(|| tokio::sync::Mutex::new(()));

// Note: 编码拒绝必须穿透回退链，见 .agents/notes/implemented/bug-fix/2026-09-25-video-codec-gates.md
#[derive(Debug, PartialEq, Eq)]
enum VideoSourceResolution {
    Found(String, Vec<u8>),
    CodecRejected,
    NotFound,
}

impl VideoSourceResolution {
    fn is_terminal(&self) -> bool {
        !matches!(self, Self::NotFound)
    }
}

// ---------------------------------------------------------------------------
// video.go
// ---------------------------------------------------------------------------

fn handle_video<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let video_id = default_val(&params.get_str("video_id"), &params.get_str("item_ids"));
        if video_id.is_empty() {
            return Err(ApiError::BadRequest("缺少video_id参数".to_string()));
        }

        let stream_mode = params.get_str("mode") == "stream";
        let raw = if stream_mode {
            fetch_shortplay_video_model(ctx, &video_id).await?
        } else {
            fetch_phoenix_video_model(ctx, &video_id).await?
        };

        let (video_url, content_key) = match resolve_video_source(ctx, &raw).await {
            VideoSourceResolution::Found(url, key) => (url, key),
            VideoSourceResolution::CodecRejected => {
                return Err(ApiError::Internal("该视频暂不支持播放".to_string()));
            }
            VideoSourceResolution::NotFound => {
                let data: Value = serde_json::from_slice(&raw)
                    .map_err(|e| ApiError::Internal(format!("parse upstream json: {e}")))?;
                return Ok(data);
            }
        };

        let source = json!({
            "video_url": video_url,
            "key_hex": hex::encode(&content_key),
            "video_id": video_id,
            // 全量兼容档（高→低）。官方面板按该列表渲染清晰度行；空数组
            // 表示单流，客户端隐藏清晰度入口。
            "variants": extract_stream_variants(ctx, &raw).await,
        });
        if stream_mode {
            return Ok(source);
        }

        match download_and_save(ctx, &video_id, &video_url, &content_key).await {
            Ok(local_path) => {
                let main_url = local_path.clone();
                Ok(json!({
                    "video_url": local_path,
                    "video_id": video_id,
                    "video_info": {
                        "data": {
                            "video_list": {
                                "video_1": { "main_url": main_url },
                            },
                        },
                    },
                }))
            }
            // Legacy clients recursively extract URLs from raw payloads;
            // only the already-selected variant may survive a download error.
            Err(_) => Ok(source),
        }
    })
}

/// Queries the phoenix multi_video_model endpoint.
async fn fetch_phoenix_video_model(ctx: &Ctx, video_id: &str) -> ApiResult<Vec<u8>> {
    let post_body = serde_json::to_vec(&json!({
        "biz_param": {
            "detail_page_version": 0,
            "device_level": 3,
            "disable_digg_stat": false,
            "need_all_video_definition": true,
            "need_mp4_align": false,
            "use_os_player": false,
            "use_server_dns": false,
            "video_platform": 1024,
        },
        "mixed_video_id_map": {
            "1004": [video_id],
        },
    }))
    .map_err(|e| ApiError::Internal(format!("marshal phoenix video body: {e}")))?;

    Upstream::new(ctx.up.clone())
        .raw(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(phoenix_player_url()),
            body: Some(post_body),
            headers: phoenix_player_headers(),
            ..Default::default()
        })
        .await
}

/// Queries the shortplay-style video_model endpoint used for short drama ids.
async fn fetch_shortplay_video_model(ctx: &Ctx, video_id: &str) -> ApiResult<Vec<u8>> {
    let post_body = serde_json::to_vec(&json!({
        "video_id": video_id,
        "content_type": 1004,
        "biz_param": {
            "detail_page_version": 0,
            "device_level": 3,
            "disable_digg_stat": false,
            "disable_video_relate_book": false,
            "from_video_id": "",
            "need_all_video_definition": true,
            "need_mp4_align": false,
            "source": 4,
            "use_os_player": false,
            "use_server_dns": false,
            "video_platform": 3,
        },
    }))
    .map_err(|e| ApiError::Internal(format!("marshal shortplay video body: {e}")))?;

    Upstream::new(ctx.up.clone())
        .raw(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(SHORTPLAY_VIDEO_MODEL_URL.to_string()),
            body: Some(post_body),
            headers: dragon_read_json_headers(),
            ..Default::default()
        })
        .await
}

/// Parses the multi_video_model response and extracts the best quality MP4 URL.
fn extract_video_url(raw: &[u8]) -> VideoSourceResolution {
    let Ok(resp) = serde_json::from_slice::<Value>(raw) else {
        return VideoSourceResolution::NotFound;
    };
    let Some(data) = resp.get("data").and_then(|d| d.as_object()) else {
        return VideoSourceResolution::NotFound;
    };

    let direct = extract_video_info_list_map_url(data);
    if direct.is_terminal() {
        return direct;
    }

    for model in video_models(data) {
        let source = extract_video_model_url(&model);
        if source.is_terminal() {
            return source;
        }
    }
    VideoSourceResolution::NotFound
}

fn extract_video_info_list_map_url(data: &Map<String, Value>) -> VideoSourceResolution {
    let Some(video_map) = data.get("video_info_list_map").and_then(|v| v.as_object()) else {
        return VideoSourceResolution::NotFound;
    };

    let mut video_list: Option<&Vec<Value>> = None;
    for v in video_map.values() {
        if let Some(arr) = v.as_array() {
            if !arr.is_empty() {
                video_list = Some(arr);
                break;
            }
        }
    }
    let Some(video_list) = video_list else {
        return VideoSourceResolution::NotFound;
    };
    let Some(video_info) = video_list[0].as_object() else {
        return VideoSourceResolution::NotFound;
    };
    let Some(play_info_list) = video_info.get("play_info_list").and_then(|v| v.as_array()) else {
        return VideoSourceResolution::NotFound;
    };
    extract_video_list_source(play_info_list)
}

async fn resolve_video_source(ctx: &Ctx, raw: &[u8]) -> VideoSourceResolution {
    let Ok(resp) = serde_json::from_slice::<Value>(raw) else {
        return VideoSourceResolution::NotFound;
    };
    let Some(data) = resp.get("data").and_then(|d| d.as_object()) else {
        return VideoSourceResolution::NotFound;
    };

    for model in video_models(data) {
        let source = extract_shortplay_video_model_source(&model);
        if source.is_terminal() {
            return source;
        }
        if !video_model_encrypted(&model) {
            continue;
        }
        let fallback_url = fallback_api_url(&model);
        if fallback_url.is_empty() {
            continue;
        }
        if let Some(fallback_data) = fetch_fallback_video_info(ctx, &fallback_url).await {
            let source = extract_fallback_video_source(&fallback_data);
            if source.is_terminal() {
                return source;
            }
        }
    }

    extract_video_url(raw)
}

fn extract_shortplay_video_model_source(model: &Map<String, Value>) -> VideoSourceResolution {
    let Some(video_list) = model.get("video_list").and_then(|v| v.as_object()) else {
        return VideoSourceResolution::NotFound;
    };
    let key_seed = model
        .get("key_seed")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .and_then(|s| audio_b64_decode(s).ok());

    select_video_source(video_list.values(), |info| {
        // Missing keys may prevent resolution, but must not hide a codec rejection.
        decrypt_variant_entry(info, key_seed.as_deref())
    })
}

/// Decrypts one `video_list` entry into a playable (url, content key) pair.
/// Shared by the best-stream selector and the multi-variant listing so both
/// apply the same URL decryption and per-variant spade key derivation.
/// `key_seed` is the model-level decoded seed bytes shared by every variant.
fn decrypt_variant_entry(
    info: &Map<String, Value>,
    key_seed: Option<&[u8]>,
) -> Option<(String, Vec<u8>)> {
    let key_seed = key_seed?;
    let mut raw_url = info
        .get("main_url")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if raw_url.is_empty() {
        raw_url = info
            .get("backup_url_1")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
    }
    if !raw_url.is_empty() && !raw_url.starts_with("http") {
        if let Ok(dec) = audio_b64_decode(&raw_url) {
            if !dec.is_empty() {
                raw_url = String::from_utf8_lossy(&dec).into_owned();
            }
        }
    }
    let u = decrypt_spade_url(&raw_url, key_seed);
    if u.is_empty() {
        return None;
    }
    let spade_a = info.get("spade_a").and_then(|v| v.as_str()).unwrap_or("");
    Some((u, derive_spade_content_key(spade_a)))
}

/// Display name for a variant height, mirroring the official mapping
/// (`zj3/b.java:76-99`): 360P/480P/540P/720P/1080P. The official panel maps
/// TwoK/FourK to an empty label, but the engine enum carries them
/// (`ttvideoengine/Resolution.java`), so taller variants use 2K/4K instead of
/// rendering a blank row.
fn variant_display_name(height: i64) -> String {
    if height <= 0 {
        return String::new();
    }
    if height <= 360 {
        "360P".to_string()
    } else if height <= 480 {
        "480P".to_string()
    } else if height <= 540 {
        "540P".to_string()
    } else if height <= 720 {
        "720P".to_string()
    } else if height <= 1080 {
        "1080P".to_string()
    } else if height <= 1440 {
        "2K".to_string()
    } else {
        "4K".to_string()
    }
}

/// All playable variants of the first encrypted short-play video model,
/// best-quality first (official panel lists resolutions high→low,
/// `ShortSeriesMorePanelDialogV2$d$C0025d.a()` with `CollectionsKt.reversed`).
/// The bytevc2 gate applies unchanged: rejected codecs never become variants.
/// When the primary model yields no list, the fallback video-info endpoint is
/// queried the same way `resolve_video_source` does. Returns `[]` when the
/// response has no multi-variant model — the client then hides the quality
/// row entirely (official `oi3/k.P()` gate).
async fn extract_stream_variants(ctx: &Ctx, raw: &[u8]) -> Vec<Value> {
    let Ok(resp) = serde_json::from_slice::<Value>(raw) else {
        return Vec::new();
    };
    let Some(data) = resp.get("data").and_then(|d| d.as_object()) else {
        return Vec::new();
    };
    for model in video_models(data) {
        // NOTE: 不用 video_model_encrypted() 做前置——它只认数组形状的
        // video_list；实测漫剧（series 7686494169098898456）的 video_list 是
        // object 且未标 encrypt，但每档照常带 spade_a/kid，选流门照常适用。
        let primary = variant_rows(
            model.get("video_list").and_then(|v| v.as_object()),
            model
                .get("key_seed")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .and_then(|s| audio_b64_decode(s).ok()),
        );
        if !primary.is_empty() {
            return primary;
        }
        let fallback_url = fallback_api_url(&model);
        if fallback_url.is_empty() {
            continue;
        }
        let Some(fallback_data) = fetch_fallback_video_info(ctx, &fallback_url).await else {
            continue;
        };
        let list = fallback_data
            .get("video_info")
            .and_then(|v| v.get("data"))
            .and_then(|v| v.as_object());
        let key_seed = list
            .and_then(|d| d.get("key_seed"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .and_then(|s| audio_b64_decode(s).ok());
        let list = list
            .and_then(|d| d.get("video_list"))
            .and_then(|v| v.as_object());
        let rows = variant_rows(list, key_seed);
        if !rows.is_empty() {
            return rows;
        }
    }
    Vec::new()
}

/// Builds the sorted variant list from one `video_list` object.
fn variant_rows(video_list: Option<&Map<String, Value>>, key_seed: Option<Vec<u8>>) -> Vec<Value> {
    let Some(video_list) = video_list else {
        return Vec::new();
    };
    let mut rows: Vec<(i64, Value)> = video_list
        .values()
        .filter_map(|v| v.as_object())
        .filter_map(|info| {
            let score = video_quality_score(info)?;
            let (url, key) = decrypt_variant_entry(info, key_seed.as_deref())?;
            let w = int64_from_any(info.get("vwidth").unwrap_or(&Value::Null));
            let h = int64_from_any(info.get("vheight").unwrap_or(&Value::Null));
            // 档位语义按**短边**：竖屏剧 1280×720 是 720P 而非 2K
            // （官方 Resolution 枚举同样以短边为准）。
            let short_edge = if w > 0 && h > 0 { w.min(h) } else { w.max(h) };
            Some((
                score,
                json!({
                    "name": variant_display_name(short_edge),
                    "width": w,
                    "height": h,
                    "url": url,
                    "key_hex": hex::encode(&key),
                }),
            ))
        })
        .collect();
    rows.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    rows.into_iter().map(|(_, v)| v).collect()
}

pub(crate) fn decode_video_model_str(s: &str) -> Option<Map<String, Value>> {
    if s.is_empty() {
        return None;
    }
    match serde_json::from_str::<Value>(s) {
        Ok(Value::Object(m)) => Some(m),
        _ => None,
    }
}

fn video_models(data: &Map<String, Value>) -> impl Iterator<Item = Map<String, Value>> + '_ {
    data.get("video_model")
        .into_iter()
        .chain(data.values().filter_map(|item| item.get("video_model")))
        .filter_map(decode_video_model)
}

fn decode_video_model(v: &Value) -> Option<Map<String, Value>> {
    match v {
        Value::Object(m) => Some(m.clone()),
        Value::String(s) => decode_video_model_str(s),
        _ => None,
    }
}

fn extract_video_model_url(model: &Map<String, Value>) -> VideoSourceResolution {
    let Some(video_list) = model.get("video_list").and_then(|v| v.as_array()) else {
        return VideoSourceResolution::NotFound;
    };
    extract_video_list_source(video_list)
}

fn extract_video_list_source(video_list: &[Value]) -> VideoSourceResolution {
    // Preserve the legacy last-entry preference when quality metadata is absent.
    select_video_source(video_list.iter().rev(), |info| {
        ["play_url", "main_url"]
            .iter()
            .filter_map(|key| info.get(*key).and_then(|v| v.as_str()))
            .find(|url| !url.is_empty())
            .map(|url| (url.to_string(), Vec::new()))
    })
}

fn video_model_encrypted(model: &Map<String, Value>) -> bool {
    let Some(video_list) = model.get("video_list").and_then(|v| v.as_array()) else {
        return false;
    };
    for item in video_list {
        let Some(info) = item.as_object() else {
            continue;
        };
        let Some(encrypt_info) = info.get("encrypt_info").and_then(|v| v.as_object()) else {
            continue;
        };
        if encrypt_info
            .get("encrypt")
            .and_then(|b| b.as_bool())
            .unwrap_or(false)
        {
            return true;
        }
    }
    false
}

fn fallback_api_url(model: &Map<String, Value>) -> String {
    let mut u = String::new();
    match model.get("fallback_api") {
        Some(Value::Object(f)) => {
            u = f
                .get("fallback_api")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
        }
        Some(Value::String(f)) => {
            if let Ok(Value::Object(m)) = serde_json::from_str::<Value>(f) {
                u = m
                    .get("fallback_api")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
            }
            if u.is_empty() {
                u = f.clone();
            }
        }
        _ => {}
    }
    u = u.replace("&stream_type=audio_encrypt", "");
    u = u.replace("?stream_type=audio_encrypt&", "?");
    u
}

async fn fetch_fallback_video_info(ctx: &Ctx, u: &str) -> Option<Map<String, Value>> {
    let raw = unsigned_get(ctx, u, FALLBACK_USER_AGENT).await?;
    serde_json::from_slice::<Value>(&raw)
        .ok()?
        .as_object()
        .cloned()
}

fn extract_fallback_video_source(root: &Map<String, Value>) -> VideoSourceResolution {
    let Some(video_info) = root.get("video_info").and_then(|v| v.as_object()) else {
        return VideoSourceResolution::NotFound;
    };
    let Some(data_root) = video_info.get("data").and_then(|v| v.as_object()) else {
        return VideoSourceResolution::NotFound;
    };
    let key_seed = data_root
        .get("key_seed")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .and_then(|s| audio_b64_decode(s).ok());
    let Some(video_list) = data_root.get("video_list").and_then(|v| v.as_object()) else {
        return VideoSourceResolution::NotFound;
    };

    select_video_source(video_list.values(), |info| {
        let key_seed = key_seed.as_deref()?;
        let mut raw_url = info
            .get("main_url")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if raw_url.is_empty() {
            raw_url = info
                .get("backup_url_1")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
        }
        let u = decrypt_spade_url(&raw_url, key_seed);
        if u.is_empty() {
            return None;
        }
        let spade_a = info.get("spade_a").and_then(|v| v.as_str()).unwrap_or("");
        Some((u, derive_spade_content_key(spade_a)))
    })
}

fn select_video_source<'a>(
    variants: impl Iterator<Item = &'a Value>,
    mut resolve: impl FnMut(&Map<String, Value>) -> Option<(String, Vec<u8>)>,
) -> VideoSourceResolution {
    let mut unresolved = VideoSourceResolution::NotFound;
    let mut infos: Vec<_> = variants
        .filter_map(|v| v.as_object())
        .filter_map(|info| match video_quality_score(info) {
            Some(score) => Some((score, info)),
            None => {
                unresolved = VideoSourceResolution::CodecRejected;
                None
            }
        })
        .collect();
    infos.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    for (_, info) in infos {
        if let Some((url, key)) = resolve(info) {
            return VideoSourceResolution::Found(url, key);
        }
    }
    unresolved
}

fn video_quality_score(info: &Map<String, Value>) -> Option<i64> {
    // Codec gates mirror the reference short-drama client: bytevc2
    // (H.266-class) has no decoder on the playback path, so a variant that
    // carries it must never win the quality race even as a last resort;
    // H.264 decodes everywhere, so it wins ties at equal quality.
    let codec = {
        let mut value = String::new();
        if let Some(v) = info.get("codec_type").and_then(|v| v.as_str()) {
            value.push_str(&v.to_lowercase());
        }
        if let Some(meta) = info.get("video_meta").and_then(|v| v.as_object()) {
            if let Some(v) = meta.get("codec_type").and_then(|v| v.as_str()) {
                value.push(' ');
                value.push_str(&v.to_lowercase());
            }
        }
        if let Some(v) = info.get("gear_des_key").and_then(|v| v.as_str()) {
            value.push(' ');
            value.push_str(&v.to_lowercase());
        }
        value
    };
    if codec.contains("bytevc2") {
        return None;
    }
    let w = int64_from_any(info.get("vwidth").unwrap_or(&Value::Null));
    let h = int64_from_any(info.get("vheight").unwrap_or(&Value::Null));
    let mut b = int64_from_any(info.get("bitrate").unwrap_or(&Value::Null));
    if b == 0 {
        b = int64_from_any(info.get("real_bitrate").unwrap_or(&Value::Null));
    }
    let bonus = i64::from(codec.contains("h264") || codec.contains("avc1"));
    Some(w * 1_000_000_000 + h * 1_000_000 + b + bonus)
}

fn int64_from_any(v: &Value) -> i64 {
    match v {
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i
            } else if let Some(u) = n.as_u64() {
                u as i64
            } else {
                n.as_f64().unwrap_or(0.0) as i64
            }
        }
        Value::String(s) => scan_i64(s),
        _ => 0,
    }
}

fn scan_i64(s: &str) -> i64 {
    let t = s.trim();
    let mut chars = t.chars().peekable();
    let mut sign = 1i64;
    match chars.peek() {
        Some('-') => {
            sign = -1;
            chars.next();
        }
        Some('+') => {
            chars.next();
        }
        _ => {}
    }
    let mut digits = String::new();
    while let Some(&c) = chars.peek() {
        if c.is_ascii_digit() {
            digits.push(c);
            chars.next();
        } else {
            break;
        }
    }
    if digits.is_empty() {
        0
    } else {
        digits.parse::<i64>().unwrap_or(0) * sign
    }
}

fn audio_b64_decode(s: &str) -> Result<Vec<u8>, base64::DecodeError> {
    let trimmed = s.trim();
    let pad = (4 - trimmed.len() % 4) % 4;
    let mut padded = trimmed.to_string();
    for _ in 0..pad {
        padded.push('=');
    }
    let cleaned: String = padded
        .chars()
        .filter(|c| *c != '\r' && *c != '\n')
        .collect();
    base64::engine::general_purpose::STANDARD.decode(cleaned)
}

fn decrypt_spade_url(value: &str, key_seed: &[u8]) -> String {
    if value.is_empty() {
        return String::new();
    }
    let Ok(raw) = audio_b64_decode(value) else {
        return value.to_string();
    };
    if raw.len() < 5 || raw[0] != 168 || raw[2] != 1 || raw[3] != 0 {
        return value.to_string();
    }
    let mut cipher_data = &raw[4..];
    let cipher_len = cipher_data.len() / 16 * 16;
    cipher_data = &cipher_data[..cipher_len];
    if cipher_data.is_empty() {
        return value.to_string();
    }

    let mut h1 = Sha512::new();
    h1.update(key_seed);
    let h1 = h1.finalize();
    let mut seed = Vec::with_capacity(64 + SPADE_CONSTANTS.len());
    seed.extend_from_slice(&h1);
    seed.extend_from_slice(&SPADE_CONSTANTS);
    let mut h2 = Sha512::new();
    h2.update(&seed);
    let h2 = h2.finalize();

    let out = crate::crypto::aes_cbc_decrypt(cipher_data, &h2[..16], &h2[16..32]);
    let out = crate::crypto::pkcs7_unpad(&out, 16);
    String::from_utf8_lossy(out)
        .trim_end_matches('\0')
        .to_string()
}

pub(crate) fn derive_spade_content_key(value: &str) -> Vec<u8> {
    if value.is_empty() {
        return Vec::new();
    }
    let Ok(raw) = audio_b64_decode(value) else {
        return Vec::new();
    };
    if raw.len() < 3 {
        return Vec::new();
    }
    let out_len = raw.len() as i64 - (raw[0] ^ raw[1] ^ raw[2]) as i64 + 0x2F;
    if out_len < 33 || out_len + 1 > raw.len() as i64 {
        return Vec::new();
    }
    let out_len = out_len as usize;
    let mut buf = raw[1..1 + out_len].to_vec();
    let src = buf.clone();
    let mut prev_a: u8 = 0x55;
    let mut prev_b: u8 = 0xF6;
    for (i, &cur) in src.iter().enumerate() {
        let keep;
        if i & 1 == 1 {
            keep = cur;
        } else {
            keep = prev_a;
            prev_a = prev_b;
            prev_b = cur;
        }
        buf[i] = (((prev_a ^ cur) as i32 - bit_count(i as u32) - 0x15) & 0xFF) as u8;
        prev_a = keep;
    }
    let key_hex = String::from_utf8_lossy(&buf[1..33]);
    match hex::decode(key_hex.as_bytes()) {
        Ok(key) if key.len() == 16 => key,
        _ => Vec::new(),
    }
}

fn bit_count(n: u32) -> i32 {
    n.count_ones() as i32
}

// ---------------------------------------------------------------------------
// video_detail.go
// ---------------------------------------------------------------------------

fn handle_video_detail<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let series_id = video_detail_series_id(params)?;
        let (platform, has_platform) = optional_int(&params.get_str("video_platform"));
        let body = video_detail_body(
            &series_id,
            int_default(&params.get_str("video_id_type"), 1),
            int_default(&params.get_str("source"), 5),
            platform,
            has_platform,
        )?;

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                method: Some("POST".to_string()),
                raw_url: Some(video_detail_url()),
                body: Some(body),
                headers: phoenix_player_headers(),
                ..Default::default()
            })
            .await
    })
}

fn video_detail_series_id(params: &Params) -> ApiResult<String> {
    let series_id = {
        let primary = params.get_str("series_id");
        if primary.is_empty() {
            default_val(&params.get_str("video_id"), &params.get_str("item_ids"))
        } else {
            primary
        }
    };
    if series_id.is_empty() {
        return Err(ApiError::BadRequest("缺少series_id参数".to_string()));
    }
    Ok(series_id)
}

fn video_detail_url() -> String {
    phoenix_player_url().replacen("/novel/player/multi_video_model/v1/", VIDEO_DETAIL_PATH, 1)
}

fn optional_int(raw: &str) -> (i64, bool) {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return (0, false);
    }
    (int_default(trimmed, 0), true)
}

fn video_detail_body(
    series_id: &str,
    video_id_type: i64,
    source: i64,
    video_platform: i64,
    has_platform: bool,
) -> ApiResult<Vec<u8>> {
    let mut biz_param = Map::new();
    biz_param.insert("device_level".to_string(), json!(3));
    biz_param.insert("need_all_video_definition".to_string(), json!(true));
    biz_param.insert("need_mp4_align".to_string(), json!(false));
    biz_param.insert("source".to_string(), json!(source));
    biz_param.insert("use_os_player".to_string(), json!(false));
    biz_param.insert("video_id_type".to_string(), json!(video_id_type));
    if has_platform {
        biz_param.insert("video_platform".to_string(), json!(video_platform));
    }

    let mut out = Map::new();
    out.insert(
        "series_id".to_string(),
        Value::String(series_id.to_string()),
    );
    out.insert("biz_param".to_string(), Value::Object(biz_param));
    serde_json::to_vec(&out)
        .map_err(|e| ApiError::Internal(format!("marshal video detail body: {e}")))
}

// ---------------------------------------------------------------------------
// pseries.go
// ---------------------------------------------------------------------------

fn handle_pseries<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let pseries_id = params.get_str("pseries_id");
        if pseries_id.is_empty() {
            return Err(ApiError::BadRequest("缺少pseries_id参数".to_string()));
        }
        let offset = default_val(&params.get_str("offset"), "1");
        let count = default_val(&params.get_str("count"), "30");
        let total = default_val(&params.get_str("total"), "80");
        let pseries_type = default_val(&params.get_str("pseries_type"), "5");

        let post_body = serde_json::to_vec(&json!({
            "biz_param": {
                "detail_page_version": 0,
                "device_level": 3,
                "disable_digg_stat": false,
                "need_all_video_definition": true,
                "need_mp4_align": false,
                "use_os_player": false,
                "use_server_dns": false,
                "video_platform": 1024,
                "pseries_type": pseries_type,
                "offset": offset,
                "count": count,
                "total": total,
                "from_category": "search",
                "category_name": "related",
                "mode": "range",
                "continue_play": 0,
            },
            "mixed_video_id_map": {
                "1004": [pseries_id],
            },
        }))
        .map_err(|e| ApiError::Internal(format!("marshal pseries body: {e}")))?;

        let result = Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                raw_url: Some(phoenix_player_url()),
                body: Some(post_body),
                headers: phoenix_player_headers(),
                ..Default::default()
            })
            .await?;

        if let Some(m) = crate::json::as_map(&result) {
            match crate::json::numeric_code(m.get("code").unwrap_or(&Value::Null)) {
                Some(code) if code != 0.0 => {
                    eprintln!(
                        "pseries {}: player endpoint code={}, trying directory fallback",
                        pseries_id, code as i64
                    );
                    match directory_reading(ctx, &pseries_id).await {
                        Ok(dir_result) => {
                            if let Some(dm) = crate::json::as_map(&dir_result) {
                                match crate::json::numeric_code(
                                    dm.get("code").unwrap_or(&Value::Null),
                                ) {
                                    Some(0.0) => {
                                        eprintln!(
                                            "pseries {}: directory fallback ok ({} items)",
                                            pseries_id,
                                            dir_item_count(dm)
                                        );
                                        return Ok(dir_result);
                                    }
                                    _ => {
                                        eprintln!(
                                            "pseries {}: directory fallback code={:?}",
                                            pseries_id,
                                            dm.get("code")
                                        );
                                    }
                                }
                            }
                        }
                        Err(dir_err) => {
                            eprintln!(
                                "pseries {}: directory fallback transport error: {}",
                                pseries_id, dir_err
                            );
                        }
                    }
                }
                _ => {
                    eprintln!(
                        "pseries {}: player code not numeric or zero: {:?}",
                        pseries_id,
                        m.get("code")
                    );
                }
            }
        } else {
            eprintln!("pseries {}: response is not an object", pseries_id);
        }

        Ok(result)
    })
}

/// reading from directory.go, copied so pseries can fall back to it.
async fn directory_reading(ctx: &Ctx, book_id: &str) -> ApiResult<Value> {
    let u = format!(
        "{DIRECTORY_READING_URL}book_type=0&item_data_list_md5=&catalog_data_md5=&book_id={}{DIRECTORY_READING_QUERY_SUFFIX}",
        go_query_escape(book_id)
    );
    Upstream::new(ctx.up.clone())
        .json(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(u),
            headers: user_agent_headers(UA_ANDROID_BROWSER),
            ..Default::default()
        })
        .await
}

fn dir_item_count(dm: &Map<String, Value>) -> i64 {
    let data = crate::json::extract_upstream_data(&Value::Object(dm.clone()));
    if let Some(inner) = crate::json::as_map(&data) {
        for key in ["item_data_list", "item_list", "lists"] {
            if let Some(list) = inner.get(key).and_then(|v| v.as_array()) {
                return list.len() as i64;
            }
        }
    }
    -1
}

// ---------------------------------------------------------------------------
// HTTP + on-disk cache
// ---------------------------------------------------------------------------

/// Plain, unsigned GET with an explicit User-Agent.
async fn unsigned_get(ctx: &Ctx, url: &str, user_agent: &str) -> Option<Vec<u8>> {
    let req = UpstreamRequest {
        method: Some("GET".to_string()),
        url: url.to_string(),
        body: None,
        headers: vec![("User-Agent".to_string(), user_agent.to_string())],
        no_sign: true,
        pin: None,
    };
    match ctx.up.do_request(&req).await {
        Ok((body, _)) => Some(body),
        Err(_) => None,
    }
}

/// Downloads the MP4, saves it to src/, and returns the served path.
async fn download_and_save(
    ctx: &Ctx,
    video_id: &str,
    video_url: &str,
    content_key: &[u8],
) -> Result<String, String> {
    let _guard = VIDEO_CACHE_LOCK.lock().await;

    let src_dir = if ctx.src_dir.is_empty() {
        "src".to_string()
    } else {
        ctx.src_dir.clone()
    };
    std::fs::create_dir_all(&src_dir).map_err(|e| e.to_string())?;

    let mut ext = ".mp4".to_string();
    if let Some(idx) = video_url.rfind('.') {
        if idx > 0 {
            let candidate = video_url[idx..].to_lowercase();
            if candidate.len() <= 5
                && (candidate == ".mp4" || candidate == ".m4s" || candidate == ".ts")
            {
                ext = candidate;
            }
        }
    }

    let filename = format!("{video_id}{ext}");
    let fp = Path::new(&src_dir).join(&filename);

    if let Ok(info) = std::fs::metadata(&fp) {
        if info.len() > 0 {
            if !content_key.is_empty() {
                if let Err(err) = decrypt_cached_video_if_needed(&fp, content_key) {
                    let _ = std::fs::remove_file(&fp);
                    return Err(err);
                }
            }
            return Ok(format!("/src/{filename}"));
        }
    }

    let part_path = PathBuf::from(format!("{}.part", fp.display()));
    let _ = std::fs::remove_file(&part_path);

    let data = unsigned_get(ctx, video_url, UA_WINDOWS_BROWSER)
        .await
        .ok_or_else(|| "download video: request failed".to_string())?;
    std::fs::write(&part_path, &data).map_err(|e| e.to_string())?;

    if !content_key.is_empty() {
        if let Err(err) = decrypt_cached_video_if_needed(&part_path, content_key) {
            let _ = std::fs::remove_file(&part_path);
            return Err(err);
        }
    }
    if let Err(err) = std::fs::rename(&part_path, &fp) {
        let _ = std::fs::remove_file(&part_path);
        return Err(err.to_string());
    }
    prune_video_cache(&src_dir, &fp);

    Ok(format!("/src/{filename}"))
}

const MAX_VIDEO_CACHE_BYTES: i64 = 512 * 1024 * 1024;

struct CacheEntry {
    path: PathBuf,
    size: u64,
    when: std::time::SystemTime,
}

/// Removes the oldest completed video files once the cache exceeds the limit.
fn prune_video_cache(src_dir: &str, keep: &Path) {
    let Ok(entries) = std::fs::read_dir(src_dir) else {
        return;
    };
    let mut items: Vec<CacheEntry> = Vec::new();
    let mut total: i64 = 0;
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.ends_with(".part") || name.ends_with(".tmp") {
            continue;
        }
        let ext = Path::new(&name)
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        if ext != "mp4" && ext != "m4s" && ext != "ts" {
            continue;
        }
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if !meta.is_file() || meta.len() == 0 {
            continue;
        }
        let when = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
        total += meta.len() as i64;
        items.push(CacheEntry {
            path: Path::new(src_dir).join(&name),
            size: meta.len(),
            when,
        });
    }
    if total <= MAX_VIDEO_CACHE_BYTES {
        return;
    }
    items.sort_by_key(|a| a.when);
    for item in items {
        if total <= MAX_VIDEO_CACHE_BYTES {
            continue;
        }
        if item.path.as_path() == keep {
            continue;
        }
        if std::fs::remove_file(&item.path).is_ok() {
            total -= item.size as i64;
        }
    }
}

fn decrypt_cached_video_if_needed(fp: &Path, content_key: &[u8]) -> Result<(), String> {
    let data = std::fs::read(fp).map_err(|e| e.to_string())?;
    if !mp4_needs_cenc_decrypt(&data) {
        return Ok(());
    }
    let mut buf = data.clone();
    decrypt_cenc_mp4(&mut buf, content_key)?;
    let tmp = PathBuf::from(format!("{}.tmp", fp.display()));
    std::fs::write(&tmp, &buf).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, fp).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// MP4 CENC decryption
// ---------------------------------------------------------------------------

fn u16_be(data: &[u8], off: usize) -> u16 {
    if off + 2 > data.len() {
        return 0;
    }
    u16::from_be_bytes([data[off], data[off + 1]])
}

fn u32_be(data: &[u8], off: usize) -> u32 {
    if off + 4 > data.len() {
        return 0;
    }
    u32::from_be_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]])
}

fn u64_be(data: &[u8], off: usize) -> u64 {
    if off + 8 > data.len() {
        return 0;
    }
    let mut b = [0u8; 8];
    b.copy_from_slice(&data[off..off + 8]);
    u64::from_be_bytes(b)
}

#[derive(Clone, Copy)]
struct Mp4Box {
    off: usize,
    size: usize,
    header: usize,
    typ: [u8; 4],
}

fn iter_boxes(data: &[u8], start: usize, end: usize) -> Vec<Mp4Box> {
    let end = end.min(data.len());
    let mut boxes = Vec::new();
    let mut off = start;
    while off + 8 <= end {
        let mut size = u32_be(data, off) as usize;
        let mut typ = [0u8; 4];
        typ.copy_from_slice(&data[off + 4..off + 8]);
        let mut header = 8usize;
        if size == 1 {
            if off + 16 > end {
                break;
            }
            let size64 = u64_be(data, off + 8);
            if size64 > isize::MAX as u64 {
                break;
            }
            size = size64 as usize;
            header = 16;
        } else if size == 0 {
            size = end - off;
        }
        if size < header || off + size > end {
            break;
        }
        boxes.push(Mp4Box {
            off,
            size,
            header,
            typ,
        });
        off += size;
    }
    boxes
}

fn box_children_start(typ: &[u8; 4], off: usize, header: usize) -> Option<usize> {
    match typ {
        b"moov" | b"trak" | b"mdia" | b"minf" | b"stbl" | b"dinf" | b"edts" | b"udta" => {
            Some(off + header)
        }
        b"stsd" => Some(off + header + 8),
        b"encv" | b"avc1" | b"hvc1" | b"hev1" => Some(off + header + 78),
        b"enca" | b"mp4a" => Some(off + header + 28),
        _ => None,
    }
}

fn collect_track_boxes(data: &[u8], start: usize, end: usize) -> HashMap<[u8; 4], Vec<Mp4Box>> {
    let mut found: HashMap<[u8; 4], Vec<Mp4Box>> = HashMap::new();
    walk_boxes(data, start, end, &mut found);
    found
}

fn walk_boxes(
    data: &[u8],
    child_start: usize,
    child_end: usize,
    found: &mut HashMap<[u8; 4], Vec<Mp4Box>>,
) {
    for b in iter_boxes(data, child_start, child_end) {
        found.entry(b.typ).or_default().push(b);
        if let Some(nested_start) = box_children_start(&b.typ, b.off, b.header) {
            if nested_start < b.off + b.size {
                walk_boxes(data, nested_start, b.off + b.size, found);
            }
        }
    }
}

fn mp4_track_boxes(data: &[u8]) -> Vec<HashMap<[u8; 4], Vec<Mp4Box>>> {
    let mut tracks = Vec::new();
    for b in iter_boxes(data, 0, data.len()) {
        if b.typ != *b"moov" {
            continue;
        }
        for child in iter_boxes(data, b.off + b.header, b.off + b.size) {
            if child.typ == *b"trak" {
                tracks.push(collect_track_boxes(
                    data,
                    child.off + child.header,
                    child.off + child.size,
                ));
            }
        }
    }
    tracks
}

fn mp4_needs_cenc_decrypt(data: &[u8]) -> bool {
    for boxes in mp4_track_boxes(data) {
        if boxes.get(b"encv").is_some_and(|v| !v.is_empty())
            || boxes.get(b"enca").is_some_and(|v| !v.is_empty())
        {
            return true;
        }
    }
    false
}

fn decrypt_cenc_mp4(data: &mut [u8], content_key: &[u8]) -> Result<(), String> {
    if content_key.len() != 16 && content_key.len() != 24 && content_key.len() != 32 {
        return Err("invalid CENC content key length".to_string());
    }
    for boxes in mp4_track_boxes(data) {
        rewrite_encrypted_sample_entries(data, &boxes);
        let senc_boxes = boxes.get(b"senc").cloned().unwrap_or_default();
        let stsz_boxes = boxes.get(b"stsz").cloned().unwrap_or_default();
        let stsc_boxes = boxes.get(b"stsc").cloned().unwrap_or_default();
        if senc_boxes.is_empty() || stsz_boxes.is_empty() || stsc_boxes.is_empty() {
            continue;
        }
        let chunk_box = if let Some(b) = boxes.get(b"stco").and_then(|v| v.first()) {
            *b
        } else if let Some(b) = boxes.get(b"co64").and_then(|v| v.first()) {
            *b
        } else {
            continue;
        };

        let sample_sizes = parse_stsz(data, stsz_boxes[0]);
        let chunk_offsets = parse_chunk_offsets(data, chunk_box);
        let stsc_entries = parse_stsc(data, stsc_boxes[0]);
        let samples = sample_offsets(&stsc_entries, &chunk_offsets, &sample_sizes);
        let mut iv_size = track_iv_size(data, &boxes);
        if iv_size == 0 {
            iv_size = 8;
        }
        let senc_entries = parse_senc(data, senc_boxes[0], iv_size);
        let n = samples.len().min(senc_entries.len());
        for i in 0..n {
            let sample = samples[i];
            let entry = &senc_entries[i];
            if sample.size == 0 {
                continue;
            }
            let mut ranges: Vec<ByteRange> = Vec::new();
            if !entry.subsamples.is_empty() {
                let mut pos = sample.off;
                for sub in &entry.subsamples {
                    pos += sub.clear;
                    if sub.encrypted > 0 {
                        ranges.push(ByteRange {
                            off: pos,
                            size: sub.encrypted,
                        });
                    }
                    pos += sub.encrypted;
                }
            } else {
                ranges.push(ByteRange {
                    off: sample.off,
                    size: sample.size,
                });
            }
            ctr_crypt_ranges(data, content_key, &entry.iv, &ranges)?;
        }
    }
    Ok(())
}

fn rewrite_encrypted_sample_entries(data: &mut [u8], boxes: &HashMap<[u8; 4], Vec<Mp4Box>>) {
    for (typ, replacement) in [(b"encv", b"hvc1"), (b"enca", b"mp4a")] {
        let Some(list) = boxes.get(typ) else {
            continue;
        };
        for b in list {
            if b.off + 8 <= data.len() {
                data[b.off + 4..b.off + 8].copy_from_slice(replacement);
            }
            let Some(child_start) = box_children_start(typ, b.off, b.header) else {
                continue;
            };
            for child in iter_boxes(data, child_start, b.off + b.size) {
                if child.typ == *b"sinf" {
                    if child.off + 8 <= data.len() {
                        data[child.off..child.off + 4].copy_from_slice(&8u32.to_be_bytes());
                        data[child.off + 4..child.off + 8].copy_from_slice(b"free");
                    }
                    let start = child.off + 8;
                    let end = (child.off + child.size).min(data.len());
                    if start < end {
                        for byte in &mut data[start..end] {
                            *byte = 0;
                        }
                    }
                    break;
                }
            }
        }
    }
}

fn parse_stsz(data: &[u8], b: Mp4Box) -> Vec<usize> {
    let mut p = b.off + 12;
    if p + 8 > data.len() {
        return Vec::new();
    }
    let sample_size = u32_be(data, p) as usize;
    let sample_count = u32_be(data, p + 4) as usize;
    p += 8;
    let mut out = Vec::new();
    if sample_size != 0 {
        for _ in 0..sample_count {
            out.push(sample_size);
        }
        return out;
    }
    let mut i = 0;
    while i < sample_count && p + i * 4 + 4 <= data.len() {
        out.push(u32_be(data, p + i * 4) as usize);
        i += 1;
    }
    out
}

fn parse_chunk_offsets(data: &[u8], b: Mp4Box) -> Vec<usize> {
    let mut p = b.off + 12;
    if p + 4 > data.len() {
        return Vec::new();
    }
    let entry_count = u32_be(data, p) as usize;
    p += 4;
    let mut out = Vec::new();
    if b.typ == *b"co64" {
        let mut i = 0;
        while i < entry_count && p + i * 8 + 8 <= data.len() {
            out.push(u64_be(data, p + i * 8) as usize);
            i += 1;
        }
        return out;
    }
    let mut i = 0;
    while i < entry_count && p + i * 4 + 4 <= data.len() {
        out.push(u32_be(data, p + i * 4) as usize);
        i += 1;
    }
    out
}

#[derive(Clone, Copy)]
struct StscEntry {
    first_chunk: usize,
    samples_per_chunk: usize,
}

fn parse_stsc(data: &[u8], b: Mp4Box) -> Vec<StscEntry> {
    let mut p = b.off + 12;
    if p + 4 > data.len() {
        return Vec::new();
    }
    let entry_count = u32_be(data, p) as usize;
    p += 4;
    let mut out = Vec::new();
    let mut i = 0;
    while i < entry_count && p + i * 12 + 12 <= data.len() {
        out.push(StscEntry {
            first_chunk: u32_be(data, p + i * 12) as usize,
            samples_per_chunk: u32_be(data, p + i * 12 + 4) as usize,
        });
        i += 1;
    }
    out
}

#[derive(Clone, Copy)]
struct SampleRange {
    off: usize,
    size: usize,
}

fn sample_offsets(
    stsc_entries: &[StscEntry],
    chunk_offsets: &[usize],
    sample_sizes: &[usize],
) -> Vec<SampleRange> {
    let mut offsets = Vec::new();
    let mut sample_index = 0usize;
    let mut stsc_index = 0usize;
    for (chunk_index, &chunk_off) in chunk_offsets.iter().enumerate() {
        let one_based_chunk = chunk_index + 1;
        while stsc_index + 1 < stsc_entries.len()
            && stsc_entries[stsc_index + 1].first_chunk <= one_based_chunk
        {
            stsc_index += 1;
        }
        if stsc_index >= stsc_entries.len() {
            break;
        }
        let mut off = chunk_off;
        for _ in 0..stsc_entries[stsc_index].samples_per_chunk {
            if sample_index >= sample_sizes.len() {
                return offsets;
            }
            let size = sample_sizes[sample_index];
            offsets.push(SampleRange { off, size });
            off += size;
            sample_index += 1;
        }
    }
    offsets
}

fn track_iv_size(data: &[u8], boxes: &HashMap<[u8; 4], Vec<Mp4Box>>) -> usize {
    if let Some(list) = boxes.get(b"tenc") {
        for b in list {
            if b.size >= 32 && b.off + 16 <= data.len() {
                return data[b.off + 15] as usize;
            }
        }
    }
    0
}

struct SubsampleRange {
    clear: usize,
    encrypted: usize,
}

struct SencEntry {
    iv: Vec<u8>,
    subsamples: Vec<SubsampleRange>,
}

fn parse_senc(data: &[u8], b: Mp4Box, iv_size: usize) -> Vec<SencEntry> {
    if b.off + 16 > data.len() {
        return Vec::new();
    }
    let flags =
        (data[b.off + 9] as i32) << 16 | (data[b.off + 10] as i32) << 8 | data[b.off + 11] as i32;
    let sample_count = u32_be(data, b.off + 12) as usize;
    let mut p = b.off + 16;
    let mut end = b.off + b.size;
    if end > data.len() {
        end = data.len();
    }
    let mut entries = Vec::new();
    for _ in 0..sample_count {
        if p + iv_size > end {
            break;
        }
        let iv = data[p..p + iv_size].to_vec();
        p += iv_size;
        let mut subsamples = Vec::new();
        if flags & 0x02 != 0 {
            if p + 2 > end {
                break;
            }
            let subsample_count = u16_be(data, p) as usize;
            p += 2;
            for _ in 0..subsample_count {
                if p + 6 > end {
                    break;
                }
                subsamples.push(SubsampleRange {
                    clear: u16_be(data, p) as usize,
                    encrypted: u32_be(data, p + 2) as usize,
                });
                p += 6;
            }
        }
        entries.push(SencEntry { iv, subsamples });
    }
    entries
}

struct ByteRange {
    off: usize,
    size: usize,
}

fn aes_encrypt_block(key: &[u8], block: &[u8; 16]) -> Result<[u8; 16], String> {
    use aes::cipher::generic_array::GenericArray;
    use aes::cipher::{BlockEncrypt, KeyInit};
    let mut b = GenericArray::clone_from_slice(block);
    match key.len() {
        16 => {
            let cipher =
                aes::Aes128::new_from_slice(key).map_err(|_| "invalid AES key".to_string())?;
            cipher.encrypt_block(&mut b);
        }
        24 => {
            let cipher =
                aes::Aes192::new_from_slice(key).map_err(|_| "invalid AES key".to_string())?;
            cipher.encrypt_block(&mut b);
        }
        32 => {
            let cipher =
                aes::Aes256::new_from_slice(key).map_err(|_| "invalid AES key".to_string())?;
            cipher.encrypt_block(&mut b);
        }
        n => return Err(format!("invalid AES key length {n}")),
    }
    let mut out = [0u8; 16];
    out.copy_from_slice(&b);
    Ok(out)
}

fn ctr_crypt_ranges(
    data: &mut [u8],
    content_key: &[u8],
    iv: &[u8],
    ranges: &[ByteRange],
) -> Result<(), String> {
    if ranges.is_empty() {
        return Ok(());
    }
    let mut counter = [0u8; 16];
    match iv.len() {
        8 => counter[..8].copy_from_slice(iv),
        16 => counter.copy_from_slice(iv),
        n => return Err(format!("unsupported CENC IV size: {n}")),
    }

    let mut keystream = [0u8; 16];
    let mut keystream_pos = 16usize;
    for r in ranges {
        if r.size == 0 || r.off + r.size > data.len() {
            continue;
        }
        for i in 0..r.size {
            if keystream_pos == 16 {
                keystream = aes_encrypt_block(content_key, &counter)?;
                for byte in counter.iter_mut().rev() {
                    *byte = byte.wrapping_add(1);
                    if *byte != 0 {
                        break;
                    }
                }
                keystream_pos = 0;
            }
            data[r.off + i] ^= keystream[keystream_pos];
            keystream_pos += 1;
        }
    }
    Ok(())
}

pub fn register(s: &mut Server) {
    s.add_route("video", handle_video);
    s.add_route("video_detail", handle_video_detail);
    s.add_route("pseries", handle_pseries);
}

#[cfg(test)]
mod spade_vectors {
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
        let rows = variant_rows(video_list.as_object(), Some(b"AAAA".to_vec()));
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
}

#[cfg(test)]
mod cenc_sample_fixture {
    //! Offline contract for CENC sample decryption (video.rs).
    //!
    //! The MP4 comes from the offline fixture generator: a minimal
    //! `moov/trak/mdia/minf/stbl` with `stsd(encv)`, `stsz`, `stsc`, `stco`,
    //! `senc` and `tenc`, plus an encrypted `mdat`. It was encrypted by an
    //! independent AES-CTR implementation and stored the plaintext samples, so
    //! this test compares the decryption against data the Rust side never
    //! produced.

    use super::*;

    const FIXTURE: &str = include_str!("../../testdata/cenc_sample_fixture.json");

    fn fixture() -> serde_json::Value {
        serde_json::from_str(FIXTURE).expect("cenc_sample_fixture.json")
    }

    fn b64(f: &serde_json::Value, key: &str) -> Vec<u8> {
        base64::engine::general_purpose::STANDARD
            .decode(f[key].as_str().expect(key))
            .expect("base64 fixture")
    }

    fn plain_samples(f: &serde_json::Value, key: &str) -> Vec<Vec<u8>> {
        f[key]
            .as_array()
            .expect(key)
            .iter()
            .map(|v| {
                base64::engine::general_purpose::STANDARD
                    .decode(v.as_str().expect("sample"))
                    .expect("base64 sample")
            })
            .collect()
    }

    /// The encrypted `mdat` starts at the offset the generator reported for
    /// that case (the two cases have different moov sizes).
    fn encrypted_region(file: &[u8], f: &serde_json::Value, key: &str) -> Vec<u8> {
        let off = f[key].as_u64().expect(key) as usize;
        file[off..].to_vec()
    }

    #[test]
    fn detects_encrypted_tracks_and_rewrites_the_sample_entry() {
        let f = fixture();
        let c = &f["cenc"];
        let mut file = b64(c, "full_sample_b64");
        assert!(mp4_needs_cenc_decrypt(&file), "encv must be detected");

        let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
        decrypt_cenc_mp4(&mut file, &key).expect("decrypt");

        // encv -> hvc1 and sinf -> free, so a re-run must no longer see it as
        // encrypted (that is what makes the call idempotent).
        assert!(
            !mp4_needs_cenc_decrypt(&file),
            "the sample entry must be rewritten to a clear one"
        );
    }

    #[test]
    fn decrypts_every_whole_encrypted_sample_with_the_go_plaintext() {
        let f = fixture();
        let c = &f["cenc"];
        let mut file = b64(c, "full_sample_b64");
        let expected = plain_samples(c, "full_sample_plain_b64");
        let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();

        // The samples are laid out contiguously in mdat, in stsz order.
        let before = encrypted_region(&file, c, "full_mdat_offset");
        decrypt_cenc_mp4(&mut file, &key).expect("decrypt");
        let after = encrypted_region(&file, c, "full_mdat_offset");

        let mut cursor = 0usize;
        for (i, want) in expected.iter().enumerate() {
            let got = &after[cursor..cursor + want.len()];
            assert_eq!(got, want.as_slice(), "sample {i}");
            // Go's ciphertext must differ from the plaintext for a non-trivial
            // sample, otherwise the comparison proves nothing.
            assert_ne!(
                &before[cursor..cursor + want.len()],
                want.as_slice(),
                "sample {i} was not actually encrypted"
            );
            cursor += want.len();
        }
        assert_eq!(cursor, after.len(), "all samples covered");
    }

    #[test]
    fn decrypts_subsample_encrypted_payloads_and_keeps_the_clear_header() {
        let f = fixture();
        let c = &f["cenc"];
        let mut file = b64(c, "subsample_b64");
        let expected = plain_samples(c, "subsample_plain_b64");
        let clear_head = c["subsample_clear_head"].as_u64().unwrap() as usize;
        let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();

        decrypt_cenc_mp4(&mut file, &key).expect("decrypt");
        let after = encrypted_region(&file, c, "subsample_mdat_offset");

        let mut cursor = 0usize;
        for (i, want) in expected.iter().enumerate() {
            let got = &after[cursor..cursor + want.len()];
            assert_eq!(got, want.as_slice(), "sample {i}");
            // senc flags=2 marks the head as clear: it must survive untouched.
            assert_eq!(
                &got[..clear_head],
                &want[..clear_head],
                "sample {i} clear head"
            );
            cursor += want.len();
        }
    }

    #[test]
    fn a_wrong_key_produces_different_bytes_and_a_bad_length_is_rejected() {
        let f = fixture();
        let c = &f["cenc"];
        let mut file = b64(c, "full_sample_b64");
        let original = file.clone();
        let expected = plain_samples(c, "full_sample_plain_b64");

        assert!(decrypt_cenc_mp4(&mut file.clone(), &[0u8; 7]).is_err());
        decrypt_cenc_mp4(&mut file, &[0xAAu8; 16]).expect("wrong key still decrypts");
        let after = encrypted_region(&file, c, "full_mdat_offset");
        assert_ne!(
            &after[..expected[0].len()],
            expected[0].as_slice(),
            "a wrong key must not reproduce the Go plaintext"
        );
        assert_ne!(file, original, "the wrong key must have changed the bytes");
    }

    /// The production entry point is the one that must be idempotent: it gates
    /// on the sample entry, so a second pass over an already-decrypted file must
    /// not XOR the samples again (CENC CTR is symmetric, so that would corrupt
    /// the video).
    #[test]
    fn the_cached_video_path_decrypts_once_and_is_idempotent() {
        let f = fixture();
        let c = &f["cenc"];
        let expected = plain_samples(c, "full_sample_plain_b64");
        let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();

        let dir = std::env::temp_dir().join(format!(
            "fqapp-cenc-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("sample.mp4");
        std::fs::write(&path, b64(c, "full_sample_b64")).expect("write fixture");

        decrypt_cached_video_if_needed(&path, &key).expect("first pass");
        let once = std::fs::read(&path).expect("read once");
        let region = &once[c["full_mdat_offset"].as_u64().unwrap() as usize..];
        assert_eq!(
            &region[..expected[0].len()],
            expected[0].as_slice(),
            "the first pass must produce the Go plaintext"
        );
        assert!(!mp4_needs_cenc_decrypt(&once), "encv must be rewritten");

        // Second pass: no encrypted sample entry left, so nothing is touched.
        decrypt_cached_video_if_needed(&path, &key).expect("second pass");
        let twice = std::fs::read(&path).expect("read twice");
        assert_eq!(once, twice, "the second pass must be a no-op");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
