//! Book-family endpoints: `book_detail_legacy`, `book`, `directory`,
//! `novel_detail`, `related`, `forum_id`, `item_info` and `book_share`.
//! Port of `book_detail_legacy.go`, `book.go`, `directory.go`,
//! `novel_detail.go`, `related.go`, `forum_id.go`, `iteminfo.go` and
//! `book_share.go`. The private `reading724Params` builder is copied from
//! `content_util.go` (it is not exposed by the Rust `content_util` module).

use futures::future::BoxFuture;
use once_cell::sync::Lazy;
use rand::Rng;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::base::{
    dragon_read_headers, dragon_read_json_headers, Upstream, UpstreamMode, UpstreamRequestSpec,
    HOST_FQNOVEL, HOST_NOVEL_SNSSDK, UA_ANDROID_BROWSER,
};
use crate::endpoints::util::{clean_item_ids, default_val, go_query_escape, user_agent_headers};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};
use crate::sign::abogus::generate_a_bogus;

/// Go's `reading724Params` (content_util.go).
fn reading724_params() -> Params {
    let mut p = Params::new();
    p.set("iid", "{install_id}");
    p.set("device_id", "{device_id}");
    p.set("ac", "wifi");
    p.set("channel", "xiaomi_1967_64");
    p.set("aid", "1967");
    p.set("app_name", "novelapp");
    p.set("version_code", "72432");
    p.set("version_name", "7.2.4.32");
    p.set("device_platform", "android");
    p.set("os", "android");
    p.set("ssmix", "a");
    p.set("device_type", "25053RT47C");
    p.set("device_brand", "Redmi");
    p.set("language", "zh");
    p.set("os_api", "36");
    p.set("os_version", "16");
    p.set("manifest_version_code", "72432");
    p.set("resolution", "1280*2620");
    p.set("dpi", "520");
    p.set("update_version_code", "72432");
    p.set("host_abi", "arm64-v8a");
    p.set("dragon_device_type", "phone");
    p.set("pv_player", "72432");
    p.set("compliance_status", "0");
    p.set("need_personal_recommend", "1");
    p.set("player_so_load", "1");
    p.set("is_android_pad_screen", "0");
    p.set("rom_version", "miui_V816_OS3.0.9.0.WOLCNXM");
    p
}

/// Go's `reading724LargeScreenParams` (content_util.go).
fn reading724_large_screen_params() -> Vec<(String, String)> {
    let mut p = reading724_params();
    p.set("resolution", "1280*2772");
    p.to_pairs()
}

// -------------------------------------------------------------------------
// book_detail_legacy
// -------------------------------------------------------------------------

const BOOK_DETAIL_LEGACY_PATH: &str = "/reading/bookapi/detail/v";
const BOOK_DETAIL_LEGACY_QUERY_SUFFIX: &str = "&aid=1967&app_name=novelapp&channel=xiaomi_1967_64&version_code=65132&version_name=6.5.1.32&device_platform=android&os=android&device_id={device_id}&iid={install_id}&ssmix=a&device_type=FRD-AL10&device_brand=honor&language=zh&os_api=28&os_version=9&manifest_version_code=65132&resolution=1080*1920&dpi=480&update_version_code=65132&pv_player=65132&ac=wifi&host_abi=arm64-v8a&dragon_device_type=phone&rom_version=FRD-AL10%2B8.0.0.556%28C00%29&compliance_status=0";

fn book_detail_legacy<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest("缺少book_id参数".to_string()));
        }

        let u = format!(
            "{HOST_FQNOVEL}{BOOK_DETAIL_LEGACY_PATH}?book_id={}{BOOK_DETAIL_LEGACY_QUERY_SUFFIX}",
            go_query_escape(&book_id)
        );

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                raw_url: Some(u),
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

// -------------------------------------------------------------------------
// book
// -------------------------------------------------------------------------

const BOOK_DIRECTORY_DETAIL_URL: &str = "https://fanqienovel.com/api/reader/directory/detail?";
const BOOK_USER_AGENT: &str = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36";
const MS_TOKEN_CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn book_headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), BOOK_USER_AGENT.to_string()),
        ("Accept".to_string(), "application/json".to_string()),
    ]
}

/// Go's `generateMsToken`.
fn generate_ms_token(length: usize) -> String {
    let mut rng = rand::thread_rng();
    let mut b: Vec<u8> = Vec::with_capacity(length);
    for _ in 0..length {
        b.push(MS_TOKEN_CHARS[rng.gen_range(0..MS_TOKEN_CHARS.len())]);
    }
    String::from_utf8(b).unwrap_or_default()
}

fn book<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest("缺少book_id参数".to_string()));
        }

        let query_string = format!("bookId={book_id}");
        let a_bogus = generate_a_bogus(&query_string, BOOK_USER_AGENT);
        let ms_token = generate_ms_token(182);

        let u = format!(
            "{BOOK_DIRECTORY_DETAIL_URL}{query_string}&msToken={}&a_bogus={}",
            go_query_escape(&ms_token),
            go_query_escape(&a_bogus)
        );

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::NoSign,
                raw_url: Some(u),
                headers: book_headers(),
                ..Default::default()
            })
            .await
    })
}

// -------------------------------------------------------------------------
// directory
// -------------------------------------------------------------------------

const DIRECTORY_READING_PATH: &str = "/reading/bookapi/directory/all_items/v";
const DIRECTORY_READING_QUERY_SUFFIX: &str = "&book_info_md5=&need_version=true&device_id={device_id}&ac=wifi&channel=xiaomi_1967_64&aid=1967&app_name=novelapp&version_code=65132&version_name=6.5.1.32&device_platform=android&os=android&ssmix=a&device_type=FRD-AL10&device_brand=honor&language=zh&os_api=28&os_version=9&manifest_version_code=65132&resolution=1080*1920&dpi=480&update_version_code=65132&pv_player=65132&=&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&host_abi=arm64-v8a&dragon_device_type=phone&rom_version=FRD-AL10+8.0.0.556%28C00%29&compliance_status=0";
const DIRECTORY_NOVEL_PATH: &str = "/api/novel/book/directory/list/v1/";
const DIRECTORY_NOVEL_BOOK_ID_PREFIX: &str =
    "&channel=tt_huawei2019_yz&version_code=708&device_platform=android&parent_enterfrom=&book_id=";
const DIRECTORY_NOVEL_QUERY_SUFFIX: &str = "&aid=13&device_type=25053RT47C&os_version=15&openudid=5ee878397ab439b3&manifest_version_code=708&update_version_code=70899";

/// Go's `randomNumericID`: n random decimal digits.
fn random_numeric_id(n: usize) -> String {
    let mut rng = rand::thread_rng();
    let mut s = String::with_capacity(n);
    for _ in 0..n {
        s.push(char::from(b'0' + rng.gen_range(0..10u8)));
    }
    s
}

fn directory<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest(
                "missing book_id parameter".to_string(),
            ));
        }
        if params.get_str("api_type") == "novel" {
            let device_id = random_numeric_id(16);
            let u = format!(
                "{HOST_NOVEL_SNSSDK}{DIRECTORY_NOVEL_PATH}?app_name=news_article&version_name=7.0.8&app_version=7.0.8&device_id={device_id}{DIRECTORY_NOVEL_BOOK_ID_PREFIX}{}{DIRECTORY_NOVEL_QUERY_SUFFIX}",
                go_query_escape(&book_id)
            );
            return Upstream::new(ctx.up.clone())
                .json(&UpstreamRequestSpec {
                    mode: UpstreamMode::Signed,
                    raw_url: Some(u),
                    headers: user_agent_headers("com.ss.android.article.news"),
                    ..Default::default()
                })
                .await;
        }

        let u = format!(
            "{HOST_FQNOVEL}{DIRECTORY_READING_PATH}?book_type=0&item_data_list_md5=&catalog_data_md5=&book_id={}{DIRECTORY_READING_QUERY_SUFFIX}",
            go_query_escape(&book_id)
        );
        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                raw_url: Some(u),
                headers: user_agent_headers(UA_ANDROID_BROWSER),
                ..Default::default()
            })
            .await
    })
}

// -------------------------------------------------------------------------
// novel_detail
// -------------------------------------------------------------------------

const NOVEL_DETAIL_HOST: &str = "https://api3-normal-sinfonlinea.fqnovel.com";
const NOVEL_DETAIL_PATH: &str = "/reading/ugc/postdata/detail/v";

fn novel_detail_headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), "com.dragon.read/70932 (Linux; U; Android 13; zh_CN; 2112123AC; Build/TKQ1.221114.001; Cronet/TTNetVersion:b9c3e521 2025-09-09 QuicVersion:c67e9834 2025-09-08)".to_string()),
        ("Accept".to_string(), "application/json; charset=utf-8,application/x-protobuf".to_string()),
        ("x-xs-from-web".to_string(), "0".to_string()),
        ("x-vc-bdturing-sdk-version".to_string(), "4.0.3.cn".to_string()),
        ("lc".to_string(), "101".to_string()),
        ("sdk-version".to_string(), "2".to_string()),
        ("passport-sdk-version".to_string(), "5051451".to_string()),
        ("x-tt-store-region".to_string(), "cn-sc".to_string()),
        ("x-tt-store-region-src".to_string(), "uid".to_string()),
        ("x-ss-dp".to_string(), "1967".to_string()),
    ]
}

fn novel_detail<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let post_id = params.get_str("post_id");
        if post_id.is_empty() {
            return Err(ApiError::BadRequest("缺少post_id参数".to_string()));
        }

        let mut p = Params::new();
        p.set("relative_id", "0");
        p.set("source_type", "16");
        p.set("relative_type", "5");
        p.set("post_id", post_id);
        p.set("ac", "wifi");
        p.set("channel", "43536133a");
        p.set("aid", "1967");
        p.set("app_name", "novelapp");
        p.set("version_code", "70932");
        p.set("version_name", "7.0.9.32");
        p.set("device_platform", "android");
        p.set("os", "android");
        p.set("ssmix", "a");
        p.set("device_type", "2112123AC");
        p.set("device_brand", "Xiaomi");
        p.set("language", "zh");
        p.set("os_api", "33");
        p.set("os_version", "13");
        p.set("manifest_version_code", "70932");
        p.set("resolution", "1080*2313");
        p.set("dpi", "440");
        p.set("update_version_code", "70932");
        p.set("host_abi", "armeabi-v7a");
        p.set("dragon_device_type", "phone");
        p.set("pv_player", "70932");
        p.set("compliance_status", "0");
        p.set("need_personal_recommend", "1");
        p.set("player_so_load", "1");
        p.set("is_android_pad_screen", "0");
        p.set("rom_version", "miui_V816_V816.0.10.0.TLDCNXM");

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::Signed,
                host: NOVEL_DETAIL_HOST.to_string(),
                path: NOVEL_DETAIL_PATH.to_string(),
                params: p.to_pairs(),
                headers: novel_detail_headers(),
                ..Default::default()
            })
            .await
    })
}

// -------------------------------------------------------------------------
// related
// -------------------------------------------------------------------------

const RELATED_PATH: &str = "/reading/reader/book/recommend_data_plan/v";

fn related<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest(
                "missing book_id parameter".to_string(),
            ));
        }

        let mut p = reading724_params();
        p.set("book_id", book_id);
        p.set("source", "5");
        p.set("cdid", "bc6a7790-a107-46d4-8464-6ae4c148cb31");

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: RELATED_PATH.to_string(),
                params: p.to_pairs(),
                headers: user_agent_headers(UA_ANDROID_BROWSER),
                ..Default::default()
            })
            .await
    })
}

// -------------------------------------------------------------------------
// forum_id
// -------------------------------------------------------------------------

const FORUM_ID_PATH: &str = "/reading/ugc/item/mix_data/get/v";

/// `json.Marshal` in Go escapes `<`, `>` and `&` as `\u003c`, `\u003e`
/// and `\u0026`; `serde_json` does not, so apply the same escaping to the
/// serialized bytes to match the Go body byte-for-byte.
fn go_escape_json_html(body: Vec<u8>) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len());
    for b in body {
        match b {
            b'<' => out.extend_from_slice(b"\\u003c"),
            b'>' => out.extend_from_slice(b"\\u003e"),
            b'&' => out.extend_from_slice(b"\\u0026"),
            _ => out.push(b),
        }
    }
    out
}

fn forum_id<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let author_user_id = params.get_str("author_user_id");
        let book_id = params.get_str("book_id");
        let item_id = params.get_str("item_id");
        if author_user_id.is_empty() || book_id.is_empty() || item_id.is_empty() {
            return Err(ApiError::BadRequest(
                "缺少参数: author_user_id / book_id / item_id 均为必填".to_string(),
            ));
        }

        let body = go_escape_json_html(
            serde_json::to_vec(&json!({
                "author_user_id": author_user_id,
                "book_id": book_id,
                "count": 0,
                "include_other_item_data": false,
                "item_id": item_id,
                "should_not_impr": false,
                "source_type": 38,
            }))
            .map_err(|e| ApiError::Internal(e.to_string()))?,
        );

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: FORUM_ID_PATH.to_string(),
                params: reading724_large_screen_params(),
                body: Some(body),
                headers: dragon_read_json_headers(),
                ..Default::default()
            })
            .await
    })
}

// -------------------------------------------------------------------------
// item_info
// -------------------------------------------------------------------------

const ITEM_INFO_PATH: &str = "/api/novel/book/directory/detail/v/";

static ITEM_IDS_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^\d+(,\d+)*$").expect("item ids re"));

fn item_info_headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1".to_string()),
        ("Accept".to_string(), "application/json".to_string()),
        ("Referer".to_string(), format!("{HOST_NOVEL_SNSSDK}/")),
        ("Accept-Language".to_string(), "zh-CN,zh;q=0.9,en;q=0.8".to_string()),
    ]
}

fn item_info<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let raw = params.get_str("item_ids");
        if raw.is_empty() {
            return Err(ApiError::BadRequest(
                "missing item_ids parameter".to_string(),
            ));
        }
        let item_ids = clean_item_ids(&raw);
        if !ITEM_IDS_RE.is_match(&item_ids) {
            return Err(ApiError::BadRequest(
                "item_ids format invalid (comma-separated numeric ids)".to_string(),
            ));
        }

        let mut p = Params::new();
        p.set("aid", "1319");
        p.set("item_ids", item_ids);

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::NoSign,
                host: HOST_NOVEL_SNSSDK.to_string(),
                path: ITEM_INFO_PATH.to_string(),
                params: p.to_pairs(),
                headers: item_info_headers(),
                ..Default::default()
            })
            .await
    })
}

// -------------------------------------------------------------------------
// book_share
// -------------------------------------------------------------------------

const BOOK_SHARE_INFO_PATH: &str = "/reading/user/share/info/v?tone_id=0&share_type=0&group_id=";
const BOOK_SHARE_INFO_URL_SUFFIX: &str = "&only_share_status=false&status=0&ac=wifi&channel=xiaomi_1967_64&aid=1967&app_name=novelapp&version_code=65132&version_name=6.5.1.32&device_platform=android&os=android&ssmix=a&device_type=FRD-AL10&device_brand=honor&language=zh&os_api=28&os_version=9&manifest_version_code=65132&resolution=1080*1920&dpi=480&update_version_code=65132&pv_player=65132&gender=2&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&host_abi=arm64-v8a&dragon_device_type=phone&rom_version=FRD-AL10+8.0.0.556%28C00%29&compliance_status=0";
const BOOK_SHARE_EXCERPT_PATH: &str = "/reading/bookapi/excerpt/list/v?limit=0&book_id=";
const BOOK_SHARE_EXCERPT_URL_SUFFIX: &str = "&iid={install_id}&device_id={device_id}&ac=wifi&channel=xiaomi_1967_64&aid=1967&app_name=novelapp&version_code=65132&version_name=6.5.1.32&device_platform=android&os=android&ssmix=a&device_type=FRD-AL10&device_brand=honor&language=zh&os_api=28&os_version=9&manifest_version_code=65132&resolution=1080*1920&dpi=480&update_version_code=65132&pv_player=65132&=&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&host_abi=arm64-v8a&dragon_device_type=phone&rom_version=FRD-AL10+8.0.0.556%28C00%29&compliance_status=0";

async fn raw_share_json(ctx: &Ctx, raw_url: String) -> ApiResult<Value> {
    Upstream::new(ctx.up.clone())
        .json(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(raw_url),
            headers: dragon_read_headers(),
            ..Default::default()
        })
        .await
}

fn book_share<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest("缺少book_id参数".to_string()));
        }
        let mode = default_val(&params.get_str("mode"), "both");

        let share_url = format!(
            "{HOST_FQNOVEL}{BOOK_SHARE_INFO_PATH}{}{BOOK_SHARE_INFO_URL_SUFFIX}",
            go_query_escape(&book_id)
        );
        let excerpt_url = format!(
            "{HOST_FQNOVEL}{BOOK_SHARE_EXCERPT_PATH}{}{BOOK_SHARE_EXCERPT_URL_SUFFIX}",
            go_query_escape(&book_id)
        );

        match mode.as_str() {
            "share" | "both" => raw_share_json(ctx, share_url).await,
            "excerpt" => raw_share_json(ctx, excerpt_url).await,
            _ => Ok(json!({
                "excerpts": Value::Null,
                "share_info": Value::Null,
            })),
        }
    })
}

pub fn register(s: &mut Server) {
    s.add_route("book_detail_legacy", book_detail_legacy);
    s.add_route("book", book);
    s.add_route("directory", directory);
    s.add_route("novel_detail", novel_detail);
    s.add_route("related", related);
    s.add_route("forum_id", forum_id);
    s.add_route("item_info", item_info);
    s.add_route("book_share", book_share);
}
