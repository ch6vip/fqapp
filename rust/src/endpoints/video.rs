//! Video endpoints: the multi-quality video resolver plus the short-drama
//! series detail and episode-list endpoints.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use base64::Engine;
use futures::future::BoxFuture;
use once_cell::sync::Lazy;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha512};
use tokio::io::AsyncWriteExt;

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
const SHORTPLAY_VIDEO_MODEL_URL: &str = "https://api3-normal-sinfonlinea.fqnovel.com/novel/player/video_model/v1/?iid={install_id}&device_id={device_id}&aid=1967&app_name=novelapp&version_code=72132&version_name=7.2.1.32&device_platform=android&device_brand=Xiaomi&os_version=13&cdid={cdid}";

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
        // 短剧 stream 仍以 shortplay 模型选流，但清晰度列表要合并两条接口：
        // 顶档（1080p）只出现在 phoenix 模型的 `fallback_api` 列表里，而两条
        // 接口的编码分布并不相同——shortplay 各档是 h265，phoenix 的低档是解不
        // 了的 bytevc2（实测 2026-10-12 同一集对拍）。二选一必然少档：只信
        // shortplay 会丢 1080P，只信 phoenix 会让低档被编码门整片丢掉。
        // 两个请求互不依赖，并发发出，不额外占用一个往返。
        let (raw, phoenix_raw) = if stream_mode {
            let (shortplay, phoenix) = tokio::join!(
                fetch_shortplay_video_model(ctx, &video_id),
                fetch_phoenix_video_model(ctx, &video_id),
            );
            // 凤凰那条失败原先被 `.ok()` 静默吃掉，而 1080P 只可能来自它那条
            // 列表（短剧专用接口自带列表与其 `fallback_api` 都只到 720P）——
            // 失败即面板少一档且毫无痕迹。**HTTP 成功不等于业务成功**：实测
            // 2026-10-14 三集全部回火山错误封包
            // `{BaseResp, Code:110001, Message:未知异常}`（无 `data`），上游只给
            // 通用码、不给原因，所以这里把外壳与剧集 id 一起留在核心日志里。
            // Note: 为什么静默会丢一整档、以及日志里刻意不记什么 —
            // 见 .agents/notes/implemented/bug-fix/2026-10-14-phoenix-reject-silent-quality-loss.md
            match &phoenix {
                Ok(body) if phoenix_model_usable(body) => {}
                Ok(body) => log::warn!(
                    "video {video_id}: phoenix body unusable (quality tiers lost): {}",
                    envelope_of_body(body)
                ),
                Err(error) => log::warn!(
                    "video {video_id}: phoenix request failed (quality tiers lost): {}",
                    error.message()
                ),
            }
            (shortplay?, phoenix.ok())
        } else {
            (fetch_phoenix_video_model(ctx, &video_id).await?, None)
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
            "variants": extract_stream_variants(ctx, &raw, phoenix_raw.as_deref()).await,
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
    // `main_url` 有两种形态，不能一律先解一层 base64：
    //   1) base64 包着的明文地址（解码后以 `http` 开头）；
    //   2) spade 密文（base64 解出来以 a8 00 01 00 开头），要用 key_seed 解。
    // 旧实现无条件先解一层，把第 2 种毁成了不可再解的字节串——实测
    // 2026-10-12：fallback 列表（含 1080p 那一档）全部解不出来，面板因此
    // 拿到一个不是 URL 的垃圾串。这里只认第 1 种，第 2 种把**原始 base64**
    // 交给 decrypt_spade_url 自己再解一层。
    if !raw_url.is_empty() && !raw_url.starts_with("http") {
        if let Ok(dec) = audio_b64_decode(&raw_url) {
            if dec.starts_with(b"http") {
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

/// Every playable variant across the given response bodies, best-quality first
/// (official panel lists resolutions high→low,
/// `ShortSeriesMorePanelDialogV2$d$C0025d.a()` with `CollectionsKt.reversed`).
/// The bytevc2 gate applies unchanged: rejected codecs never become variants.
///
/// Each body's `video_list` and its `fallback_api` list are merged, and several
/// bodies are merged together, because no single list is complete and they are
/// not interchangeable: 实测 2026-10-12 同一集对拍——shortplay 模型的自身列表到
/// 720P 为止（各档 h265），phoenix 模型的 fallback 才有 1080p（低档是解不了的
/// bytevc2）。只看一份会静默少档。Returns `[]` when no body yields a variant —
/// the client then hides the quality row entirely (official `oi3/k.P()` gate).
async fn extract_stream_variants(ctx: &Ctx, raw: &[u8], extra: Option<&[u8]>) -> Vec<Value> {
    let mut scored = Vec::new();
    // 读不动的 body 直接跳过、不报错：`extra`（凤凰）是不是可用由调用点判并告警，
    // 那里才有剧集 id 可以把日志和一次播放对起来。
    for body in std::iter::once(raw).chain(extra) {
        let Ok(resp) = serde_json::from_slice::<Value>(body) else {
            continue;
        };
        let Some(data) = resp.get("data").and_then(|d| d.as_object()) else {
            continue;
        };
        for model in video_models(data) {
            // NOTE: 不用 video_model_encrypted() 做前置——它只认数组形状的
            // video_list；实测漫剧（series 7686494169098898456）的 video_list 是
            // object 且未标 encrypt，但每档照常带 spade_a/kid，选流门照常适用。
            scored.extend(variant_rows_scored(
                model.get("video_list").and_then(|v| v.as_object()),
                model
                    .get("key_seed")
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.is_empty())
                    .and_then(|s| audio_b64_decode(s).ok()),
            ));
            scored.extend(fallback_variant_rows(ctx, &model).await);
        }
    }
    merge_variant_rows(scored)
}

/// The model's `fallback_api` list as scored rows; empty when the model has no
/// fallback URL or it cannot be fetched. Same endpoint `resolve_video_source`
/// falls back to.
async fn fallback_variant_rows(ctx: &Ctx, model: &Map<String, Value>) -> Vec<(i64, Value)> {
    let fallback_url = fallback_api_url(model);
    if fallback_url.is_empty() {
        // 多数模型本来就没有这一条，不是异常。
        return Vec::new();
    }
    let Some(fallback_data) = fetch_fallback_video_info(ctx, &fallback_url).await else {
        // 有地址却拉不到，是这一档列表整片消失的另一种静默路径。
        log::warn!("fallback_api fetch failed (quality tiers lost)");
        return Vec::new();
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
    variant_rows_scored(list, key_seed)
}

/// Ranks rows best-first and keeps one row per resolution. A resolution offered
/// by several lists renders once, and the list that came first wins — so the
/// tier the player actually selected stays in the list and the panel keeps
/// highlighting it (the panel matches the current tier by URL). Rows without a
/// resolution carry no label and are dropped.
fn merge_variant_rows(scored: Vec<(i64, Value)>) -> Vec<Value> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut out: Vec<(i64, Value)> = Vec::with_capacity(scored.len());
    for (score, row) in scored {
        let name = row
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if name.is_empty() || !seen.insert(name) {
            continue;
        }
        out.push((score, row));
    }
    out.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    out.into_iter().map(|(_, row)| row).collect()
}

/// 凤凰那条响应是否可用：`data` 必须是个对象。
///
/// HTTP 成功不等于业务成功——上游业务失败时回的是火山错误封包
/// `{BaseResp, Code, Message}`（无 `data`），状态码仍是 200。看状态码判不出来，
/// 只能看外壳，所以这里单独判一次由调用点告警。
fn phoenix_model_usable(body: &[u8]) -> bool {
    serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|resp| resp.get("data").map(Value::is_object))
        .unwrap_or(false)
}

/// 把一份响应的**外壳**压成一行：顶层键名、`data` 的类型、`code`/`Code`、
/// `message`/`Message` 与 `BaseResp`。
///
/// 只记键名、类型、状态码与上游消息（截断），**不记 `data` 里的值**：值里可能是带签名的
/// URL 与令牌，而这份日志会被导出给人看。上游拒绝时只给 `110001` 这类通用码，把外壳与
/// 它给的原话留在日志里，是下一次"某一档无声消失"唯一能查的线索。
fn body_envelope(resp: &Value) -> String {
    let keys = resp
        .as_object()
        .map(|map| map.keys().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    let mut line = format!(
        "keys={keys:?} data={} code={} message={}",
        json_type_of(resp.get("data")),
        envelope_scalar(resp, &["code", "Code"]),
        envelope_scalar(resp, &["message", "Message"]),
    );
    if let Some(base) = resp.get("BaseResp") {
        line.push_str(&format!(" BaseResp={}", truncated(base, 240)));
    }
    line
}

/// 一份响应字节流的外壳；不是 JSON 就报长度。
fn envelope_of_body(body: &[u8]) -> String {
    match serde_json::from_slice::<Value>(body) {
        Ok(resp) => body_envelope(&resp),
        Err(_) => format!("not json len={}", body.len()),
    }
}

/// 按候选键名取一个标量并渲染成短字符串，都取不到给 `-`。
fn envelope_scalar(resp: &Value, names: &[&str]) -> String {
    for name in names {
        match resp.get(*name) {
            Some(Value::String(text)) => return text.chars().take(120).collect(),
            Some(Value::Null) | None => continue,
            Some(other) => return other.to_string(),
        }
    }
    "-".to_string()
}

/// 把一段 JSON 压成一行并截断，避免错误包里的长文案把日志撑爆。
fn truncated(value: &Value, limit: usize) -> String {
    let text = value.to_string();
    if text.chars().count() <= limit {
        text
    } else {
        format!("{}…", text.chars().take(limit).collect::<String>())
    }
}

/// JSON 值的类型标签，`absent` 表示键根本不在。
fn json_type_of(value: Option<&Value>) -> &'static str {
    match value {
        None => "absent",
        Some(Value::Null) => "null",
        Some(Value::Bool(_)) => "bool",
        Some(Value::Number(_)) => "number",
        Some(Value::String(_)) => "string",
        Some(Value::Array(_)) => "array",
        Some(Value::Object(_)) => "object",
    }
}

/// Builds the variant rows from one `video_list` object, keeping the quality
/// score so callers can merge several upstream lists before ranking them.
fn variant_rows_scored(
    video_list: Option<&Map<String, Value>>,
    key_seed: Option<Vec<u8>>,
) -> Vec<(i64, Value)> {
    let Some(video_list) = video_list else {
        return Vec::new();
    };
    let mut rows: Vec<(i64, Value)> = video_list
        .iter()
        .filter_map(|(slot, value)| {
            let info = value.as_object()?;
            let w = int64_from_any(info.get("vwidth").unwrap_or(&Value::Null));
            let h = int64_from_any(info.get("vheight").unwrap_or(&Value::Null));
            // 档位语义按**短边**：竖屏剧 1280×720 是 720P 而非 2K
            // （官方 Resolution 枚举同样以短边为准）。
            let short_edge = if w > 0 && h > 0 { w.min(h) } else { w.max(h) };
            let name = variant_display_name(short_edge);
            // 编码门丢 bytevc2 是**预期行为**（`CRIT-004`：该编码没有解码器），不打点。
            let score = video_quality_score(info)?;
            let Some((url, key)) = decrypt_variant_entry(info, key_seed.as_deref()) else {
                // 地址解不出来是静默丢**整档**的一类——`4e85437` 修过同款缺陷，且
                // 实测夹具的 `main_url` 形态一向比线上少，缺陷容易被盖住，所以留告警。
                log::warn!("variant {slot} dropped, url undecodable ({w}x{h} {name})");
                return None;
            };
            Some((
                score,
                json!({
                    "name": name,
                    "width": w,
                    "height": h,
                    "url": url,
                    "key_hex": hex::encode(&key),
                }),
            ))
        })
        .collect();
    rows.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
    rows
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

/// Hard per-file bound for a single downloaded / cached video. A short-drama
/// episode is far below this; the cap only stops a lying `Content-Length`
/// or an endless body from filling the disk or memory.
const MAX_VIDEO_DOWNLOAD_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// Total timeout for one video download, matching the 15 s the shared
/// upstream transport applies to the old whole-body download.
const VIDEO_DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(15);

/// A plain reqwest client for streaming video downloads. The shared upstream
/// transport (`upstream/http.rs`) only exposes a whole-body API, so the
/// download path keeps its own client; it sends the same unsigned GET with
/// the same User-Agent as `unsigned_get` (no signing, no device headers).
/// Built lazily so a missing TLS provider (e.g. in a unit-test embedding,
/// where the transport never installed one) degrades to the whole-body
/// fallback instead of failing the download.
static STREAMING_CLIENT: OnceLock<Option<reqwest::Client>> = OnceLock::new();

fn streaming_client() -> Option<&'static reqwest::Client> {
    STREAMING_CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .timeout(VIDEO_DOWNLOAD_TIMEOUT)
                .build()
                .ok()
        })
        .as_ref()
}

/// Streams a video body to `part_path` chunk by chunk, never holding the
/// whole file in memory. Enforces the per-file cap from `Content-Length`
/// when present and from the running byte count while streaming. Leaves a
/// partial file behind on error; the caller deletes it.
async fn stream_download_to_file(
    url: &str,
    user_agent: &str,
    part_path: &Path,
) -> Result<u64, String> {
    stream_download_to_file_with_cap(url, user_agent, part_path, MAX_VIDEO_DOWNLOAD_BYTES).await
}

async fn stream_download_to_file_with_cap(
    url: &str,
    user_agent: &str,
    part_path: &Path,
    cap_bytes: u64,
) -> Result<u64, String> {
    let client = streaming_client().ok_or_else(|| "streaming client unavailable".to_string())?;
    let mut resp = client
        .get(url)
        .header(reqwest::header::USER_AGENT, user_agent)
        .send()
        .await
        .map_err(|e| format!("download video: {e}"))?;
    // The whole-body path rejects anything but 200; keep that contract.
    if resp.status() != reqwest::StatusCode::OK {
        return Err(format!("download video: HTTP {}", resp.status()));
    }
    if let Some(len) = resp.content_length() {
        if len > cap_bytes {
            return Err(format!(
                "download video: content-length {len} exceeds cap {cap_bytes}"
            ));
        }
    }
    let mut file = tokio::fs::File::create(part_path)
        .await
        .map_err(|e| e.to_string())?;
    let mut total: u64 = 0;
    loop {
        match resp.chunk().await {
            Ok(Some(bytes)) => {
                total = total
                    .checked_add(bytes.len() as u64)
                    .ok_or_else(|| "download video: size overflow".to_string())?;
                if total > cap_bytes {
                    return Err(format!(
                        "download video: streamed {total} bytes exceeds cap {cap_bytes}"
                    ));
                }
                file.write_all(&bytes).await.map_err(|e| e.to_string())?;
            }
            Ok(None) => break,
            Err(e) => return Err(format!("download video: {e}")),
        }
    }
    file.flush().await.map_err(|e| e.to_string())?;
    Ok(total)
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
            // The cache keeps the downloaded bytes exactly as they arrived
            // (CENC-encrypted when the source is encrypted); the serve path
            // decrypts ranges on demand. All this path has to do is keep the
            // key sidecar in place — which also repairs a sidecar lost to a
            // crash between the download's rename and its sidecar write.
            if !content_key.is_empty()
                && cache_cenc_state(&fp) == CacheCencState::Encrypted
                && read_key_sidecar(&fp).as_deref() != Some(content_key)
            {
                write_key_sidecar(&fp, content_key)?;
            }
            return Ok(format!("/src/{filename}"));
        }
    }

    let part_path = PathBuf::from(format!("{}.part", fp.display()));
    let _ = std::fs::remove_file(&part_path);

    if streaming_client().is_some() {
        // Streaming download: the body is written chunk by chunk and never
        // held whole in memory (P1-9). `VIDEO_CACHE_LOCK` above still
        // serializes downloads; the lock is kept because the cache file,
        // the key sidecar, and the prune pass below are not safe to run
        // concurrently for the same video.
        // The streaming client bypasses `UpstreamClient::do_request`, so
        // apply the mock-origin rewrite here; without it the download
        // would go to the real upstream instead of the mock server and
        // the codec-gate download tests would never see the request.
        let download_url = ctx.up.effective_url(video_url);
        if let Err(err) =
            stream_download_to_file(&download_url, UA_WINDOWS_BROWSER, &part_path).await
        {
            let _ = std::fs::remove_file(&part_path);
            return Err(err);
        }
    } else {
        // No TLS provider installed in this process (unit-test embedding
        // without the upstream transport): fall back to the shared
        // whole-body download instead of failing outright.
        let data = unsigned_get(ctx, video_url, UA_WINDOWS_BROWSER)
            .await
            .ok_or_else(|| "download video: request failed".to_string())?;
        if data.len() as u64 > MAX_VIDEO_DOWNLOAD_BYTES {
            return Err(format!(
                "download video: {} bytes exceeds cap {MAX_VIDEO_DOWNLOAD_BYTES}",
                data.len()
            ));
        }
        std::fs::write(&part_path, &data).map_err(|e| e.to_string())?;
    }

    if let Err(err) = std::fs::rename(&part_path, &fp) {
        let _ = std::fs::remove_file(&part_path);
        return Err(err.to_string());
    }
    // The bytes on disk stay exactly as downloaded — encrypted when the
    // source is CENC (P1-7). The key sidecar is what lets the serve path
    // decrypt ranges on demand, now and in later processes; if it cannot be
    // written the entry would be undecodable, so fail the download instead
    // of leaving a dead cache file behind.
    if !content_key.is_empty() && cache_cenc_state(&fp) == CacheCencState::Encrypted {
        if let Err(err) = write_key_sidecar(&fp, content_key) {
            let _ = std::fs::remove_file(&fp);
            return Err(err);
        }
    }
    prune_src_cache(&src_dir, &fp);

    Ok(format!("/src/{filename}"))
}

const MAX_VIDEO_CACHE_BYTES: i64 = 512 * 1024 * 1024;

struct CacheEntry {
    path: PathBuf,
    size: u64,
    when: std::time::SystemTime,
}

/// Removes the oldest completed cached files once the cache exceeds the
/// limit. Videos and manga images share `src_dir`, so both count toward the
/// same budget: manga images are the content-addressed `img_<sha256>.<ext>`
/// files, and they are evictable like videos (re-downloadable on demand).
/// In-flight downloads (`.part` / `.tmp`) are never counted or deleted.
pub(crate) fn prune_src_cache(src_dir: &str, keep: &Path) {
    prune_src_cache_with_budget(src_dir, keep, MAX_VIDEO_CACHE_BYTES);
}

fn prune_src_cache_with_budget(src_dir: &str, keep: &Path, max_bytes: i64) {
    let Ok(entries) = std::fs::read_dir(src_dir) else {
        return;
    };
    let entries: Vec<(String, PathBuf)> = entries
        .flatten()
        .map(|entry| {
            (
                entry.file_name().to_string_lossy().into_owned(),
                entry.path(),
            )
        })
        .collect();
    let names: HashSet<&str> = entries.iter().map(|(name, _)| name.as_str()).collect();
    // Key sidecars (`<video>.key`, P1-7) belong to their video entry: one
    // whose video (or in-flight `.part`) is gone can never serve again.
    for (name, path) in &entries {
        if let Some(stem) = name.strip_suffix(".key") {
            if !names.contains(stem) && !names.contains(format!("{stem}.part").as_str()) {
                let _ = std::fs::remove_file(path);
            }
        }
    }
    let mut items: Vec<CacheEntry> = Vec::new();
    let mut total: i64 = 0;
    for entry in entries.iter().map(|(name, _)| name) {
        let name = entry.as_str();
        if name.ends_with(".part") || name.ends_with(".tmp") {
            continue;
        }
        let ext = Path::new(name)
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let is_video = ext == "mp4" || ext == "m4s" || ext == "ts";
        // Manga images are written as `img_<sha256>.<jpg|png|gif|webp>`; the
        // `img_` prefix keeps unrelated files out of the eviction set.
        let is_manga_image = name.starts_with("img_")
            && (ext == "jpg" || ext == "png" || ext == "gif" || ext == "webp");
        if !is_video && !is_manga_image {
            continue;
        }
        let path = Path::new(src_dir).join(name);
        let Ok(meta) = std::fs::metadata(&path) else {
            continue;
        };
        if !meta.is_file() || meta.len() == 0 {
            continue;
        }
        let when = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
        total += meta.len() as i64;
        items.push(CacheEntry {
            path,
            size: meta.len(),
            when,
        });
    }
    if total <= max_bytes {
        return;
    }
    items.sort_by_key(|a| a.when);
    for item in items {
        if total <= max_bytes {
            continue;
        }
        if item.path.as_path() == keep {
            continue;
        }
        if std::fs::remove_file(&item.path).is_ok() {
            // A video's key sidecar (P1-7) is part of the entry, not a
            // separate cache citizen.
            let _ = std::fs::remove_file(key_sidecar_path(&item.path));
            total -= item.size as i64;
        }
    }
}

// ---------------------------------------------------------------------------
// Encrypted on-disk video cache (P1-7)
//
// Downloaded bytes are stored exactly as they arrived — CENC-encrypted when
// the source is encrypted — and the decrypted view exists only in memory, one
// served range at a time. The per-video content key (derived from `spade_a`
// during source resolution, never persisted before) travels in a sidecar
// file next to the cache entry: `<name>.mp4.key`, hex encoded. The cache
// directory is app-private; the sidecar is what lets a later process serve a
// cached file without re-resolving the source, and `download_and_save`'s
// cache-hit path rewrites it if it ever goes missing.
// ---------------------------------------------------------------------------

/// Upper bound for the `moov` box read at serve/migration time, matching the
/// native player core's SP_MAX_MOOV_BYTES. A larger moov is treated as
/// undetectable rather than read without bound.
const MAX_MOOV_BYTES: u64 = 16 * 1024 * 1024;

fn key_sidecar_path(fp: &Path) -> PathBuf {
    PathBuf::from(format!("{}.key", fp.display()))
}

fn write_key_sidecar(fp: &Path, content_key: &[u8]) -> Result<(), String> {
    let sidecar = key_sidecar_path(fp);
    let tmp = PathBuf::from(format!("{}.tmp", sidecar.display()));
    std::fs::write(&tmp, hex::encode(content_key)).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &sidecar).map_err(|e| e.to_string())
}

fn read_key_sidecar(fp: &Path) -> Option<Vec<u8>> {
    let raw = std::fs::read_to_string(key_sidecar_path(fp)).ok()?;
    let key = hex::decode(raw.trim()).ok()?;
    if key.len() == 16 || key.len() == 24 || key.len() == 32 {
        Some(key)
    } else {
        None
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CacheCencState {
    /// The file's `moov` carries an encrypted sample entry (encv/enca).
    Encrypted,
    /// The file parses as MP4 and no track is encrypted: either an
    /// originally-clear download or a plaintext file left by the pre-P1-7
    /// in-place decrypt. The two are indistinguishable from the bytes.
    Clear,
    /// No readable `moov` (truncated, not MP4, moov over the cap): nothing
    /// can be concluded, so callers leave the file alone.
    Unknown,
}

/// Locates the top-level `moov` box by walking box headers only.
fn locate_moov(file: &mut std::fs::File, len: u64) -> Option<(u64, u64)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut off = 0u64;
    while off + 8 <= len {
        file.seek(SeekFrom::Start(off)).ok()?;
        let mut hdr = [0u8; 16];
        file.read_exact(&mut hdr[..8]).ok()?;
        let size32 = u32::from_be_bytes(hdr[..4].try_into().ok()?);
        let (size, header) = if size32 == 1 {
            file.read_exact(&mut hdr[8..16]).ok()?;
            (u64::from_be_bytes(hdr[8..16].try_into().ok()?), 16u64)
        } else if size32 == 0 {
            (len - off, 8u64)
        } else {
            (size32 as u64, 8u64)
        };
        if size < header || off + size > len {
            return None;
        }
        if &hdr[4..8] == b"moov" {
            return Some((off, size));
        }
        off += size;
    }
    None
}

/// Reads exactly the `moov` box bytes and its file offset.
fn read_moov_bytes(path: &Path) -> Option<(u64, Vec<u8>)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let (off, size) = locate_moov(&mut file, len)?;
    if size > MAX_MOOV_BYTES {
        return None;
    }
    file.seek(SeekFrom::Start(off)).ok()?;
    let mut buf = vec![0u8; size as usize];
    file.read_exact(&mut buf).ok()?;
    Some((off, buf))
}

fn cache_cenc_state(path: &Path) -> CacheCencState {
    match read_moov_bytes(path) {
        Some((_, moov)) => {
            if mp4_needs_cenc_decrypt(&moov) {
                CacheCencState::Encrypted
            } else {
                CacheCencState::Clear
            }
        }
        None => CacheCencState::Unknown,
    }
}

/// Per-file CENC index cache: range requests from a player arrive in
/// bursts, and re-reading the moov for each one would be wasteful. Keyed by
/// path and invalidated by (length, mtime), which a re-download changes.
type CencIndexCache =
    std::sync::Mutex<HashMap<PathBuf, (u64, std::time::SystemTime, Arc<CencIndex>)>>;

static CENC_INDEX_CACHE: OnceLock<CencIndexCache> = OnceLock::new();

fn cenc_index_for_file(path: &Path) -> Result<Option<Arc<CencIndex>>, String> {
    let meta = std::fs::metadata(path).map_err(|e| e.to_string())?;
    let len = meta.len();
    let modified = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
    let cache = CENC_INDEX_CACHE.get_or_init(|| std::sync::Mutex::new(HashMap::new()));
    if let Ok(guard) = cache.lock() {
        if let Some((cached_len, cached_mtime, index)) = guard.get(path) {
            if *cached_len == len && *cached_mtime == modified {
                return Ok(Some(index.clone()));
            }
        }
    }
    let Some((moov_off, moov)) = read_moov_bytes(path) else {
        return Ok(None);
    };
    let Some(index) = build_cenc_index(&moov, moov_off, len)? else {
        return Ok(None);
    };
    let index = Arc::new(index);
    if let Ok(mut guard) = cache.lock() {
        guard.insert(path.to_path_buf(), (len, modified, index.clone()));
    }
    Ok(Some(index))
}

/// Serves one `/src/*` request for a CENC-encrypted cache file, decrypting
/// only the requested range. Returns `None` for anything that is not an
/// encrypted MP4 with a sidecar key question to answer — the caller falls
/// back to the plain static file path (clear MP4s, manga images, ...).
pub(crate) async fn serve_src_file(
    src_dir: &str,
    rest: &str,
    req: &crate::dispatch::Request,
) -> Option<crate::dispatch::Response> {
    use crate::dispatch::{Response, ResponseBody};
    let root = Path::new(src_dir);
    let path = crate::static_files::resolve_confined(root, rest).await?;
    if path.extension().and_then(|e| e.to_str()) != Some("mp4") {
        return None;
    }
    if cache_cenc_state(&path) != CacheCencState::Encrypted {
        return None;
    }
    // The file is encrypted: serving the raw bytes would hand the player
    // undecodable data with a success status, so a missing key is an
    // explicit error instead. Re-resolving the source rewrites the sidecar
    // through the cache-hit path in `download_and_save`.
    let Some(key) = read_key_sidecar(&path) else {
        return Some(Response::json(
            503,
            &serde_json::json!({
                "success": false,
                "error": "cached video key missing; re-resolve the source",
            }),
        ));
    };
    let index = match cenc_index_for_file(&path) {
        Ok(Some(index)) => index,
        Ok(None) => return None,
        Err(err) => {
            return Some(Response::json(
                500,
                &serde_json::json!({ "success": false, "error": err }),
            ));
        }
    };
    let meta = std::fs::metadata(&path).ok()?;
    let total = meta.len();
    let content_type = crate::dispatch::mime_for(&path).to_string();
    let range = crate::static_files::parse_range(req.header("range"), total);
    let is_head = req.method.eq_ignore_ascii_case("HEAD");
    let (status, offset, length, extra) = match range {
        crate::static_files::ByteRange::Full => (200u16, 0u64, total, Vec::new()),
        crate::static_files::ByteRange::Partial { start, end } => (
            206u16,
            start,
            end - start + 1,
            vec![(
                "content-range".to_string(),
                format!("bytes {start}-{end}/{total}"),
            )],
        ),
        crate::static_files::ByteRange::Unsatisfiable => {
            return Some(Response {
                status: 416,
                content_type,
                headers: vec![
                    ("accept-ranges".to_string(), "bytes".to_string()),
                    ("content-range".to_string(), format!("bytes */{total}")),
                    ("content-length".to_string(), "0".to_string()),
                ],
                body: ResponseBody::Bytes(Vec::new()),
            });
        }
    };
    let mut headers = vec![
        ("accept-ranges".to_string(), "bytes".to_string()),
        ("content-length".to_string(), length.to_string()),
    ];
    headers.extend(extra);
    let body = if is_head {
        ResponseBody::Bytes(Vec::new())
    } else {
        ResponseBody::FileDecrypted {
            path,
            offset,
            length,
            total,
            index,
            key,
        }
    };
    Some(Response {
        status,
        content_type,
        headers,
        body,
    })
}

// ---------------------------------------------------------------------------
// One-time migration: plaintext video cache cleanup (P1-7 follow-up)
//
// Versions before the streaming-decrypt change decrypted cached videos in
// place, so an upgraded install can hold plaintext MP4s in the cache
// directory. The user-facing decision (2026-10-25) is to remove them
// automatically on the first launch of the new version. The sweep is scoped
// to the Rust cache directory (`<runtime>/src`) and to completed `.mp4` /
// `.m4s` entries whose moov proves them clear; the user's offline downloads
// live in a different directory (`offline-video`, managed by the Dart
// download store) and are never touched. Best-effort throughout: failures
// are logged and retried on the next launch via the pending list, and
// nothing here may fail core init.
// ---------------------------------------------------------------------------

const CACHE_FORMAT_MARKER: &str = ".cachefmt-v2";
const CACHE_FORMAT_PENDING: &str = ".cachefmt-v2-pending";

pub(crate) fn migrate_plaintext_video_cache(src_dir: &Path) {
    let marker = src_dir.join(CACHE_FORMAT_MARKER);
    let pending_path = src_dir.join(CACHE_FORMAT_PENDING);
    let first_run = !marker.exists();

    let mut targets: Vec<PathBuf> = Vec::new();
    if first_run {
        let entries = match std::fs::read_dir(src_dir) {
            Ok(entries) => entries,
            Err(err) => {
                log::warn!("p17 migration: cannot scan {}: {err}", src_dir.display());
                return;
            }
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.ends_with(".part") || name.ends_with(".tmp") {
                continue;
            }
            let ext = Path::new(&name)
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            // `.ts` entries never passed through the MP4 CENC decrypt, so
            // they are out of scope even though they are clear by nature.
            if ext != "mp4" && ext != "m4s" {
                continue;
            }
            if entry.metadata().map(|m| m.is_file()).unwrap_or(false) {
                targets.push(entry.path());
            }
        }
    } else if let Ok(list) = std::fs::read_to_string(&pending_path) {
        // Later launches only retry the names a previous run failed to
        // remove; each one is re-tested below, so a name since reused by an
        // encrypted cache entry is kept.
        targets = list
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(|line| src_dir.join(line))
            .collect();
    } else {
        return;
    }

    let mut failed: Vec<String> = Vec::new();
    let mut removed = 0usize;
    for path in &targets {
        // Only a file that provably parses as a clear MP4 is removed. An
        // encrypted entry is the new cache format and stays; an unreadable
        // one cannot be told apart from user data and also stays (the
        // regular LRU prune ages it out).
        if cache_cenc_state(path) != CacheCencState::Clear {
            continue;
        }
        match std::fs::remove_file(path) {
            Ok(()) => {
                removed += 1;
                let _ = std::fs::remove_file(key_sidecar_path(path));
            }
            Err(err) => {
                log::warn!(
                    "p17 migration: cannot remove plaintext cache {}: {err}",
                    path.display()
                );
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    failed.push(name.to_string());
                }
            }
        }
    }
    if removed > 0 {
        log::info!("p17 migration: removed {removed} plaintext video cache file(s)");
    }
    if first_run {
        let _ = std::fs::write(&marker, b"2\n");
    }
    if failed.is_empty() {
        let _ = std::fs::remove_file(&pending_path);
    } else {
        let _ = std::fs::write(&pending_path, failed.join("\n"));
    }
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

// ---------------------------------------------------------------------------
// CENC index: everything needed to turn a byte range of the encrypted file
// into the same range of the decrypted view, without touching the rest of
// the file. Built from the `moov` box alone (sample data is never read), so
// the serve path can decrypt on demand per Range request (P1-7) — the same
// shape the native player core uses for offline files (sp_mp4_index).
// ---------------------------------------------------------------------------

/// A length-preserving header rewrite (sample-entry type, `sinf` -> `free`),
/// expressed as replacement bytes at an absolute file offset.
#[derive(Debug, Clone)]
pub struct CencPatch {
    pub off: u64,
    pub bytes: Vec<u8>,
}

/// One encrypted byte run inside a sample. `base` is the number of encrypted
/// bytes preceding this run *within the same sample*: the CENC CTR keystream
/// is continuous across a sample's encrypted runs (clear subsample parts do
/// not consume keystream), so a run's keystream starts at `counter0` advanced
/// by `base` bytes.
#[derive(Debug, Clone)]
pub struct CencEncRange {
    pub off: u64,
    pub size: u64,
    pub counter0: [u8; 16],
    pub base: u64,
}

#[derive(Debug, Clone, Default)]
pub struct CencIndex {
    /// Sorted by `off`.
    pub patches: Vec<CencPatch>,
    /// Sorted by `off`; ranges never overlap in a well-formed file.
    pub ranges: Vec<CencEncRange>,
}

/// Builds the index from a byte slice holding either a whole MP4 or exactly
/// its `moov` box. `base_off` is the file offset the slice starts at (0 for a
/// whole file, the moov offset for a moov-only slice); sample-data offsets
/// come from `stco`/`co64` values and are absolute either way. Returns `None`
/// when no track carries an encrypted sample entry.
fn build_cenc_index(
    data: &[u8],
    base_off: u64,
    file_len: u64,
) -> Result<Option<CencIndex>, String> {
    let mut index = CencIndex::default();
    let mut any_encrypted_entry = false;
    for boxes in mp4_track_boxes(data) {
        if boxes.get(b"encv").is_some_and(|v| !v.is_empty())
            || boxes.get(b"enca").is_some_and(|v| !v.is_empty())
        {
            any_encrypted_entry = true;
        }
        collect_sample_entry_patches(data, &boxes, base_off, &mut index.patches);
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
            // The whole-file decrypt only touches the keystream when the
            // sample actually has encrypted bytes; keep that tolerance so a
            // corrupt IV size on a clear sample cannot fail the whole file.
            let needs_keystream =
                entry.subsamples.is_empty() || entry.subsamples.iter().any(|s| s.encrypted > 0);
            if needs_keystream && entry.iv.len() != 8 && entry.iv.len() != 16 {
                return Err(format!("unsupported CENC IV size: {}", entry.iv.len()));
            }
            let mut counter0 = [0u8; 16];
            counter0[..entry.iv.len().min(16)].copy_from_slice(&entry.iv[..entry.iv.len().min(16)]);
            let mut base: u64 = 0;
            if !entry.subsamples.is_empty() {
                let mut pos = sample.off;
                for sub in &entry.subsamples {
                    pos += sub.clear;
                    if sub.encrypted > 0 {
                        let (off, size) = (pos as u64, sub.encrypted as u64);
                        // Mirror the whole-file decrypt: a run reaching past
                        // the end of the file is skipped and consumes no
                        // keystream.
                        if off + size <= file_len {
                            index.ranges.push(CencEncRange {
                                off,
                                size,
                                counter0,
                                base,
                            });
                            base += size;
                        }
                    }
                    pos += sub.encrypted;
                }
            } else {
                let (off, size) = (sample.off as u64, sample.size as u64);
                if off + size <= file_len {
                    index.ranges.push(CencEncRange {
                        off,
                        size,
                        counter0,
                        base: 0,
                    });
                }
            }
        }
    }
    if !any_encrypted_entry {
        return Ok(None);
    }
    index.patches.sort_by_key(|p| p.off);
    index.ranges.sort_by_key(|r| r.off);
    Ok(Some(index))
}

/// Records the rewrites `rewrite_encrypted_sample_entries` used to apply in
/// place (encv -> hvc1, enca -> mp4a, `sinf` blanked into a `free` box) as
/// offset patches instead, so the file on disk keeps its original bytes.
fn collect_sample_entry_patches(
    data: &[u8],
    boxes: &HashMap<[u8; 4], Vec<Mp4Box>>,
    base_off: u64,
    out: &mut Vec<CencPatch>,
) {
    for (typ, replacement) in [(b"encv", b"hvc1"), (b"enca", b"mp4a")] {
        let Some(list) = boxes.get(typ) else {
            continue;
        };
        for b in list {
            if b.off + 8 <= data.len() {
                out.push(CencPatch {
                    off: base_off + (b.off + 4) as u64,
                    bytes: replacement.to_vec(),
                });
            }
            let Some(child_start) = box_children_start(typ, b.off, b.header) else {
                continue;
            };
            for child in iter_boxes(data, child_start, b.off + b.size) {
                if child.typ == *b"sinf" {
                    let mut header = Vec::with_capacity(8);
                    header.extend_from_slice(&8u32.to_be_bytes());
                    header.extend_from_slice(b"free");
                    out.push(CencPatch {
                        off: base_off + child.off as u64,
                        bytes: header,
                    });
                    let start = child.off + 8;
                    let end = (child.off + child.size).min(data.len());
                    if start < end {
                        out.push(CencPatch {
                            off: base_off + start as u64,
                            bytes: vec![0u8; end - start],
                        });
                    }
                    break;
                }
            }
        }
    }
}

/// Advances a big-endian 128-bit CTR counter by `blocks` blocks.
fn ctr_counter_plus(counter0: &[u8; 16], blocks: u64) -> [u8; 16] {
    let hi = u64::from_be_bytes(counter0[0..8].try_into().expect("counter hi"));
    let lo = u64::from_be_bytes(counter0[8..16].try_into().expect("counter lo"));
    let (lo, carry) = lo.overflowing_add(blocks);
    let hi = hi.wrapping_add(carry as u64);
    let mut out = [0u8; 16];
    out[0..8].copy_from_slice(&hi.to_be_bytes());
    out[8..16].copy_from_slice(&lo.to_be_bytes());
    out
}

/// Turns `buf` — the file bytes starting at absolute offset `buf_off` — into
/// the decrypted view of the same range: header patches applied, sample data
/// XORed with the keystream at the correct per-sample position. This is the
/// single transform behind the one-shot decrypt, the FFI body materialisation
/// and the loopback streaming body, so all three agree byte for byte.
pub(crate) fn apply_cenc_index(
    buf: &mut [u8],
    buf_off: u64,
    index: &CencIndex,
    content_key: &[u8],
) -> Result<(), String> {
    if content_key.len() != 16 && content_key.len() != 24 && content_key.len() != 32 {
        return Err("invalid CENC content key length".to_string());
    }
    let buf_start = buf_off;
    let buf_end = buf_off + buf.len() as u64;
    for patch in &index.patches {
        let patch_end = patch.off + patch.bytes.len() as u64;
        let s = patch.off.max(buf_start);
        let e = patch_end.min(buf_end);
        if s < e {
            let src = &patch.bytes[(s - patch.off) as usize..(e - patch.off) as usize];
            buf[(s - buf_start) as usize..(e - buf_start) as usize].copy_from_slice(src);
        }
    }
    for range in &index.ranges {
        let range_end = range.off + range.size;
        let s = range.off.max(buf_start);
        let e = range_end.min(buf_end);
        if s >= e {
            continue;
        }
        // Keystream position of byte `s` within the sample's encrypted
        // stream; CTR blocks are generated per 16 bytes from there.
        let mut stream_pos = range.base + (s - range.off);
        let mut pos = s;
        while pos < e {
            let counter = ctr_counter_plus(&range.counter0, stream_pos / 16);
            let keystream = aes_encrypt_block(content_key, &counter)?;
            let block_off = (stream_pos % 16) as usize;
            let take = (16 - block_off).min((e - pos) as usize);
            let dst = (pos - buf_start) as usize;
            for i in 0..take {
                buf[dst + i] ^= keystream[block_off + i];
            }
            pos += take as u64;
            stream_pos += take as u64;
        }
    }
    Ok(())
}

/// Whole-file in-place decrypt, kept as the reference transform the serve
/// path is validated against: it produces exactly the bytes the per-range
/// path serves. Only tests call it now — production never decrypts a whole
/// file — so it is compiled for tests only.
#[cfg(test)]
fn decrypt_cenc_mp4(data: &mut [u8], content_key: &[u8]) -> Result<(), String> {
    if content_key.len() != 16 && content_key.len() != 24 && content_key.len() != 32 {
        return Err("invalid CENC content key length".to_string());
    }
    let Some(index) = build_cenc_index(data, 0, data.len() as u64)? else {
        return Ok(());
    };
    apply_cenc_index(data, 0, &index, content_key)
}
/// hostile box with a huge `sample_count` can OOM the process.
const MAX_STSZ_SAMPLES: usize = 10_000_000;

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
        // Fixed-size branch: the box carries no per-sample entries, so
        // `sample_count` alone must be checked against the file. The
        // declared samples must fit inside the file (they live in its
        // `mdat`), and the count itself is capped.
        if sample_count > MAX_STSZ_SAMPLES {
            return Vec::new();
        }
        match sample_count.checked_mul(sample_size) {
            Some(total) if total <= data.len() => {}
            _ => return Vec::new(),
        }
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

    /// P1-7: the cache file now stays encrypted on disk and the decrypted
    /// view is produced per served range. Applying the index range by range
    /// — unaligned probes, block-straddling slices, and a sequential
    /// small-chunk pass like the streaming body's — must reproduce the
    /// whole-file decrypt byte for byte.
    #[test]
    fn served_ranges_match_the_whole_file_decrypt() {
        let f = fixture();
        let c = &f["cenc"];
        let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
        for case in ["full_sample_b64", "subsample_b64"] {
            let encrypted = b64(c, case);
            let mut whole = encrypted.clone();
            decrypt_cenc_mp4(&mut whole, &key).expect("whole decrypt");
            assert_ne!(whole, encrypted, "{case} must actually be encrypted");

            let index = build_cenc_index(&encrypted, 0, encrypted.len() as u64)
                .expect("index build")
                .expect("encrypted fixture must produce an index");
            let mut probes: Vec<(usize, usize)> = vec![(0, encrypted.len()), (0, 28)];
            let mut off = 0;
            while off < encrypted.len() {
                probes.push((off, (encrypted.len() - off).min(37)));
                off += 37;
            }
            for (off, len) in probes {
                let mut buf = encrypted[off..off + len].to_vec();
                apply_cenc_index(&mut buf, off as u64, &index, &key).expect("apply");
                assert_eq!(buf, whole[off..off + len], "{case} range {off}+{len}");
            }
            let mut streamed = Vec::with_capacity(encrypted.len());
            let mut pos = 0usize;
            while pos < encrypted.len() {
                let take = (encrypted.len() - pos).min(7);
                let mut buf = encrypted[pos..pos + take].to_vec();
                apply_cenc_index(&mut buf, pos as u64, &index, &key).expect("chunk apply");
                streamed.extend_from_slice(&buf);
                pos += take;
            }
            assert_eq!(streamed, whole, "{case} chunked stream");
        }
    }

    fn p17_temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "fqapp-p17-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    /// The serve path builds its index from the moov box alone; that index
    /// must agree with the one built from the whole file.
    #[test]
    fn index_from_moov_slice_matches_whole_file_index() {
        let f = fixture();
        let c = &f["cenc"];
        let encrypted = b64(c, "full_sample_b64");
        let dir = p17_temp_dir("moov");
        let path = dir.join("sample.mp4");
        std::fs::write(&path, &encrypted).expect("write fixture");

        let (moov_off, moov) = read_moov_bytes(&path).expect("moov must be readable");
        assert_eq!(moov_off, 28, "fixture moov offset");
        let from_moov = build_cenc_index(&moov, moov_off, encrypted.len() as u64)
            .expect("build from moov")
            .expect("index from moov");
        let from_file = build_cenc_index(&encrypted, 0, encrypted.len() as u64)
            .expect("build from file")
            .expect("index from file");
        assert_eq!(from_moov.patches.len(), from_file.patches.len());
        for (a, b) in from_moov.patches.iter().zip(&from_file.patches) {
            assert_eq!((a.off, &a.bytes), (b.off, &b.bytes), "patch");
        }
        assert_eq!(from_moov.ranges.len(), from_file.ranges.len());
        for (a, b) in from_moov.ranges.iter().zip(&from_file.ranges) {
            assert_eq!(
                (a.off, a.size, a.base, a.counter0),
                (b.off, b.size, b.base, b.counter0),
                "range"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Cache state detection and the key sidecar roundtrip the serve path
    /// depends on: encrypted stays detectable, a decrypted copy reads as
    /// clear, garbage is unknown (and therefore never deleted blindly).
    #[test]
    fn cache_state_detection_and_sidecar_roundtrip() {
        let f = fixture();
        let c = &f["cenc"];
        let encrypted = b64(c, "full_sample_b64");
        let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
        let mut plaintext = encrypted.clone();
        decrypt_cenc_mp4(&mut plaintext, &key).expect("decrypt");

        let dir = p17_temp_dir("state");
        let enc_path = dir.join("enc.mp4");
        std::fs::write(&enc_path, &encrypted).expect("write encrypted");
        assert_eq!(cache_cenc_state(&enc_path), CacheCencState::Encrypted);
        assert!(read_key_sidecar(&enc_path).is_none());
        write_key_sidecar(&enc_path, &key).expect("write sidecar");
        assert_eq!(
            read_key_sidecar(&enc_path).expect("sidecar"),
            key,
            "sidecar must roundtrip the content key"
        );

        let plain_path = dir.join("plain.mp4");
        std::fs::write(&plain_path, &plaintext).expect("write plaintext");
        assert_eq!(cache_cenc_state(&plain_path), CacheCencState::Clear);

        let junk_path = dir.join("junk.mp4");
        std::fs::write(&junk_path, b"not an mp4 at all").expect("write junk");
        assert_eq!(cache_cenc_state(&junk_path), CacheCencState::Unknown);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The one-time migration (user decision 2026-10-25): plaintext cache
    /// files from the old in-place decrypt are removed on first run;
    /// encrypted entries, unparseable files and non-video files stay; the
    /// marker makes later runs no-ops except for pending retries, which
    /// re-test the file before deleting anything.
    #[test]
    fn migration_removes_plaintext_and_keeps_the_rest() {
        let f = fixture();
        let c = &f["cenc"];
        let encrypted = b64(c, "full_sample_b64");
        let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
        let mut plaintext = encrypted.clone();
        decrypt_cenc_mp4(&mut plaintext, &key).expect("decrypt");

        let dir = p17_temp_dir("migration");
        std::fs::write(dir.join("enc.mp4"), &encrypted).expect("enc");
        std::fs::write(dir.join("plain.mp4"), &plaintext).expect("plain");
        std::fs::write(dir.join("plain.mp4.key"), b"deadbeef").expect("plain sidecar");
        std::fs::write(dir.join("junk.mp4"), b"not an mp4").expect("junk");
        std::fs::write(dir.join("note.txt"), &plaintext).expect("note");
        std::fs::write(dir.join("clip.ts"), &plaintext).expect("ts");

        migrate_plaintext_video_cache(&dir);
        assert!(!dir.join("plain.mp4").exists(), "plaintext cache removed");
        assert!(
            !dir.join("plain.mp4.key").exists(),
            "its sidecar goes with it"
        );
        assert!(dir.join("enc.mp4").exists(), "encrypted cache kept");
        assert!(dir.join("junk.mp4").exists(), "unparseable file kept");
        assert!(dir.join("note.txt").exists(), "non-video file kept");
        assert!(
            dir.join("clip.ts").exists(),
            ".ts never went through the MP4 decrypt"
        );
        assert!(dir.join(CACHE_FORMAT_MARKER).exists(), "marker written");

        // Second run is a no-op.
        migrate_plaintext_video_cache(&dir);
        assert!(dir.join("enc.mp4").exists());

        // A pending retry removes a plaintext file that shows up later…
        std::fs::write(dir.join("late.mp4"), &plaintext).expect("late");
        std::fs::write(dir.join(CACHE_FORMAT_PENDING), b"late.mp4\n").expect("pending");
        migrate_plaintext_video_cache(&dir);
        assert!(!dir.join("late.mp4").exists(), "pending plaintext removed");
        assert!(
            !dir.join(CACHE_FORMAT_PENDING).exists(),
            "pending list cleared once empty"
        );

        // …but re-tests first: a name since reused by an encrypted entry is
        // kept, not deleted.
        std::fs::write(dir.join("reused.mp4"), &encrypted).expect("reused");
        std::fs::write(dir.join(CACHE_FORMAT_PENDING), b"reused.mp4\n").expect("pending");
        migrate_plaintext_video_cache(&dir);
        assert!(
            dir.join("reused.mp4").exists(),
            "reused encrypted name kept"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// P0-1: the fixed-size `stsz` branch used to allocate one `usize` per
    /// declared sample with no bound, so a box claiming billions of samples
    /// could OOM the process from 8 header bytes. It must reject counts
    /// whose samples cannot fit in the file, while still accepting sane
    /// fixed-size boxes.
    #[test]
    fn stsz_fixed_size_branch_rejects_absurd_sample_count() {
        fn stsz_box(sample_size: u32, sample_count: u32, file_len: usize) -> (Vec<u8>, Mp4Box) {
            let mut data = vec![0u8; file_len.max(20)];
            data[12..16].copy_from_slice(&sample_size.to_be_bytes());
            data[16..20].copy_from_slice(&sample_count.to_be_bytes());
            (
                data,
                Mp4Box {
                    off: 0,
                    size: 20,
                    header: 8,
                    typ: *b"stsz",
                },
            )
        }

        // Absurd count: would previously allocate ~32 GiB of `usize`s.
        let (data, b) = stsz_box(1024, u32::MAX, 20);
        assert!(
            parse_stsz(&data, b).is_empty(),
            "sample_count whose samples cannot fit in the file must be rejected"
        );
        // Count above the absolute cap, even with 1-byte samples.
        let (data, b) = stsz_box(1, MAX_STSZ_SAMPLES as u32 + 1, 20);
        assert!(
            parse_stsz(&data, b).is_empty(),
            "sample_count above MAX_STSZ_SAMPLES must be rejected"
        );
        // Product overflow: 2 * u32::MAX samples of u32::MAX bytes.
        let (data, b) = stsz_box(u32::MAX, 2, 20);
        assert!(
            parse_stsz(&data, b).is_empty(),
            "overflowing sample_count * sample_size must be rejected"
        );
        // Sane fixed-size box still parses.
        let (data, b) = stsz_box(100, 3, 320);
        assert_eq!(parse_stsz(&data, b), vec![100, 100, 100]);
    }

    /// P1-6: manga images (`img_*`) must count toward the same `src_dir`
    /// budget as videos and be evicted oldest-first; in-flight and
    /// unrelated files must never be deleted.
    #[test]
    fn src_cache_prune_evicts_oldest_manga_images_too() {
        let dir = std::env::temp_dir().join(format!(
            "fqapp-prune-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let write_at = |name: &str, size: usize, secs: u64| {
            let path = dir.join(name);
            std::fs::write(&path, vec![b'x'; size]).expect("write cache file");
            std::fs::File::options()
                .write(true)
                .open(&path)
                .expect("open cache file")
                .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs))
                .expect("set mtime");
            path
        };
        let old_video = write_at("old.mp4", 60, 50);
        let old_image = write_at("img_old.png", 60, 100);
        let new_image = write_at("img_new.png", 60, 200);
        let in_flight = write_at("img_tmp.png.part", 60, 10);
        let unrelated = write_at("notes.txt", 60, 10);

        // Total counted = 180 (video + 2 images); budget 100 forces eviction
        // of the oldest first: old video, then old image. The kept (newest)
        // image, the in-flight part file, and the unrelated file survive.
        prune_src_cache_with_budget(&dir.to_string_lossy(), &new_image, 100);

        assert!(!old_video.exists(), "oldest video must be evicted");
        assert!(!old_image.exists(), "oldest manga image must be evicted");
        assert!(new_image.exists(), "kept image must survive");
        assert!(in_flight.exists(), "in-flight .part must never be deleted");
        assert!(unrelated.exists(), "unrelated files must never be deleted");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// P1-9: the download must stream chunk by chunk (never hold the whole
    /// file in memory) and enforce the per-file cap, both from an
    /// advertised `Content-Length` and from the running byte count.
    /// A local TCP server stands in for the upstream host.
    async fn serve_once(
        body: Vec<u8>,
        advertised: Option<u64>,
    ) -> (u16, tokio::task::JoinHandle<()>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind test server");
        let port = listener.local_addr().expect("test server addr").port();
        let handle = tokio::spawn(async move {
            if let Ok((mut socket, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let _ = socket.read(&mut buf).await;
                let header = match advertised {
                    Some(len) => format!(
                        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {len}\r\n\r\n"
                    ),
                    None => "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_string(),
                };
                let _ = socket.write_all(header.as_bytes()).await;
                let _ = socket.write_all(&body).await;
                let _ = socket.shutdown().await;
            }
        });
        (port, handle)
    }

    fn ensure_test_crypto_provider() {
        // The streaming client is built with rustls-no-provider, so it
        // needs the process-wide default provider the upstream transport
        // normally installs at startup. Mirror `upstream/http.rs`.
        let _ = rustls::crypto::ring::default_provider().install_default();
    }

    #[tokio::test]
    async fn stream_download_writes_body_without_whole_file_buffer() {
        ensure_test_crypto_provider();
        let body: Vec<u8> = (0..10_000u32).map(|i| (i % 251) as u8).collect();
        let (port, server) = serve_once(body.clone(), Some(body.len() as u64)).await;
        let dir = std::env::temp_dir().join(format!(
            "fqapp-stream-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let part = dir.join("ep.mp4.part");
        let url = format!("http://127.0.0.1:{port}/ep.mp4");
        let total = stream_download_to_file(&url, UA_WINDOWS_BROWSER, &part)
            .await
            .expect("stream download");
        assert_eq!(total, body.len() as u64);
        assert_eq!(std::fs::read(&part).expect("read part"), body);
        let _ = server.await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn stream_download_rejects_lying_content_length() {
        ensure_test_crypto_provider();
        let body = vec![b'x'; 64];
        let (port, server) = serve_once(body, Some(MAX_VIDEO_DOWNLOAD_BYTES + 1)).await;
        let dir = std::env::temp_dir().join(format!(
            "fqapp-stream-cap-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let part = dir.join("ep.mp4.part");
        let url = format!("http://127.0.0.1:{port}/ep.mp4");
        let err = stream_download_to_file(&url, UA_WINDOWS_BROWSER, &part)
            .await
            .expect_err("lying Content-Length must be rejected");
        assert!(err.contains("content-length"), "unexpected error: {err}");
        assert!(
            !part.exists(),
            "no file must be created on precheck failure"
        );
        let _ = server.await;
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn stream_download_enforces_cap_from_running_total() {
        ensure_test_crypto_provider();
        // No advertised length: the running byte count must stop the
        // download. A small cap keeps the test fast.
        let body = vec![b'y'; 100];
        let (port, server) = serve_once(body, None).await;
        let dir = std::env::temp_dir().join(format!(
            "fqapp-stream-total-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let part = dir.join("ep.mp4.part");
        let url = format!("http://127.0.0.1:{port}/ep.mp4");
        // Exercise the same loop with a small cap via the test-only seam.
        let err = stream_download_to_file_with_cap(&url, UA_WINDOWS_BROWSER, &part, 10)
            .await
            .expect_err("stream past the cap must be rejected");
        assert!(err.contains("exceeds cap"), "unexpected error: {err}");
        let _ = server.await;
        let _ = std::fs::remove_dir_all(&dir);
    }

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
}

#[cfg(test)]
mod variant_url_shapes {
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
}
