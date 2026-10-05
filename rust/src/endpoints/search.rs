//! `search` endpoint (fanqie + reading). Port of `search.go`.

use futures::future::BoxFuture;
use serde_json::Value;

use crate::endpoints::base::{dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

const FANQIE_SEARCH_URL: &str =
    "https://api.fanqiesdk.com/api/novel/channel/homepage/search/search/v1/?";
const FANQIE_SEARCH_QUERY_SUFFIX: &str = "&enterfrom_aid=&enter_from=inner_search&app_name=news_article&version_name=7.0.8&app_version=7.0.8&channel=tt_huawei2019_yz&version_code=708&device_platform=android&parent_enterfrom=novel_list&novel_host=&aid=13&scm_version=1.0.0.4112&device_type=25053RT47C&device_brand=Redmi&language=zh&os_api=35&os_version=15&openudid={openudid}&update_version_code=70899&plugin=0&tma_jssdk_version=1.10.0.0&rom_version=miui__os2.0.209.0.volcnxm";
const READING_SEARCH_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/search/tab/v?";
const READING_SEARCH_QUERY_SUFFIX: &str = "&tab_name=store&pad_column_cover=0&is_first_enter_search=false&iid={install_id}&device_id={device_id}&ac=wifi&channel=xiaomi_1967_64&aid=1967&app_name=novelapp&version_code=65132&version_name=6.5.1.32&device_platform=android&os=android&ssmix=a&device_type=FRD-AL10&device_brand=honor&language=zh&os_api=28&os_version=9&manifest_version_code=65132&resolution=1080%2A1920&dpi=480&update_version_code=65132&pv_player=65132&gender=2&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&host_abi=arm64-v8a&dragon_device_type=phone&rom_version=FRD-AL10%2B8.0.0.556%28C00%29&compliance_status=0";

fn strip_control_chars(b: &[u8]) -> Vec<u8> {
    b.iter()
        .copied()
        .filter(|c| {
            !((*c <= 0x08) || *c == 0x0B || *c == 0x0C || (0x0E..=0x1F).contains(c) || *c == 0x7F)
        })
        .collect()
}

fn trunc_bytes(b: &[u8], n: usize) -> String {
    if b.len() <= n {
        String::from_utf8_lossy(b).into_owned()
    } else {
        format!("{}...", String::from_utf8_lossy(&b[..n]))
    }
}

async fn search_fanqie(ctx: &Ctx, query: &str, offset: &str) -> ApiResult<Value> {
    let u = format!(
        "{FANQIE_SEARCH_URL}q={}&offset={}{FANQIE_SEARCH_QUERY_SUFFIX}",
        crate::endpoints::util::go_query_escape(query),
        crate::endpoints::util::go_query_escape(offset),
    );

    let raw = Upstream::new(ctx.up.clone())
        .raw(&UpstreamRequestSpec {
            mode: UpstreamMode::Signed,
            raw_url: Some(u),
            headers: crate::endpoints::util::user_agent_headers(
                "com.ss.android.article.news/13400",
            ),
            ..Default::default()
        })
        .await?;
    let raw = strip_control_chars(&raw);
    serde_json::from_slice(&raw).map_err(|e| {
        ApiError::Internal(format!(
            "parse fanqie json: {e} (first 100: {})",
            trunc_bytes(&raw, 100)
        ))
    })
}

async fn search_reading(ctx: &Ctx, query: &str, offset: &str, q: &Params) -> ApiResult<Value> {
    let count = crate::endpoints::util::default_val(&q.get_str("count"), "0");
    let tab_type = crate::endpoints::util::default_val(&q.get_str("tab_type"), "1");
    let passback = crate::endpoints::util::default_val(&q.get_str("passback"), offset);
    let esc = crate::endpoints::util::go_query_escape;
    let u = format!(
        "{READING_SEARCH_URL}bookshelf_search_plan=4&offset={}&user_is_login=1&bookstore_tab=2&passback={}&query={}&count={}&search_source=1&clicked_content=search_history&use_lynx=false&use_correct=true&tab_type={}{READING_SEARCH_QUERY_SUFFIX}",
        esc(offset),
        esc(&passback),
        esc(query),
        esc(&count),
        esc(&tab_type),
    );
    Upstream::new(ctx.up.clone())
        .json(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(u),
            headers: dragon_read_headers(),
            ..Default::default()
        })
        .await
}

fn handle<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let query = {
            let primary = params.get_str("query");
            if primary.is_empty() {
                params.get_str("q")
            } else {
                primary
            }
        };
        if query.is_empty() {
            return Err(ApiError::BadRequest("missing query parameter".to_string()));
        }
        let offset = crate::endpoints::util::default_val(&params.get_str("offset"), "0");
        if params.get_str("search_type") == "fanqie" {
            return search_fanqie(ctx, &query, &offset).await;
        }
        search_reading(ctx, &query, &offset, params).await
    })
}

pub fn register(s: &mut Server) {
    s.add_route("search", handle);
}
