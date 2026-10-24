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
            // The suffix carries `openudid={openudid}`, and the only path that
            // substitutes device placeholders is DeviceSigned - `encode_query`
            // restores the `%7B...%7D` forms precisely so that substitution can
            // happen. Under Signed the literal placeholder went out unchanged.
            mode: UpstreamMode::DeviceSigned,
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

/// The bookstore search-bar cue words (`/reading/bookapi/search/cue/v`).
///
/// The official bar rotates `data_v1[]` with the response's `rotate_interval_ms`
/// (`SearchWordDisplayView.m` → `VerticalFlipper.setFlipInterval`). The request
/// shape follows `y.java R()`/`j0()`: `search_source=1` (BOOKSTORE),
/// `bookstore_tab` is the tab's `tab_type`, `cue_type` rides the query.
fn search_cue<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let cue_type = crate::endpoints::util::default_val(&params.get_str("cue_type"), "0");
        let bookstore_tab = crate::endpoints::util::default_val(&params.get_str("tab_type"), "2");
        let tab_name = params.get_str("tab_name");
        let mut p = crate::endpoints::home::reading724_params();
        p.set("cue_type", cue_type);
        p.set("bookstore_tab", bookstore_tab);
        p.set("user_is_login", "0");
        p.set("search_source", "1");
        if !tab_name.is_empty() {
            p.set("tab_name", tab_name.clone());
        }
        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: crate::endpoints::base::HOST_FQNOVEL.to_string(),
            path: "/reading/bookapi/search/cue/v".to_string(),
            params: p.to_pairs(),
            headers: dragon_read_headers(),
            ..Default::default()
        };
        Upstream::new(ctx.up.clone()).json(&spec).await
    })
}

/// The hot search board for the empty search screen.
///
/// Upstream is the search landing plan (`/reading/bookapi/plan/v`, scene 10),
/// passed through unchanged so the `data[].search_tag_data[].tag_title`
/// aggregation shape reaches the client parser intact — the same contract the
/// Go endpoint shipped. Parameter set ported verbatim from
/// `fqapi/internal/endpoints/hot_search.go`.
fn hot_search<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let offset = crate::endpoints::util::default_val(&params.get_str("offset"), "0");
        let scene = crate::endpoints::util::default_val(&params.get_str("scene"), "10");
        let mut p = crate::endpoints::home::reading724_params();
        // Go 的 reading724LargeScreenParams：同表不同分辨率。
        p.set("resolution", "1280*2772");
        p.set("total_chapter_num", "0");
        p.set("offset", offset);
        p.set("current_chapter_num", "0");
        p.set("search_middle_page_version", "2");
        p.set("user_is_login", "1");
        p.set("bookstore_tab", "2");
        p.set("bookstore_tab_type", "2");
        p.set("cue_context", "");
        p.set("search_source", "1");
        p.set("scene", scene);
        p.set("new_search_middle_page", "true");
        p.set("search_histories", "");
        p.set("hot_word_exchange", "false");
        p.set("last_search_page_interval", "0");
        p.set("last_book_consume_time", "0");
        p.set("limit", "0");
        p.set("pad_column_detail", "0");
        p.set("tab_name", "store");
        p.set("last_consume_interval", "0");
        p.set("from", "search_input_page");
        p.set("query_history_removed", "false");
        p.set("normal_session_cnt_in_day", "58");
        p.set("gender", "2");
        p.set("cold_start_session_cnt_in_day", "3");
        p.set("sys_mini_window", "1");
        p.set("app_mini_window", "0");
        p.set("har_status", "0");
        p.set("cold_start_session_cnt_in_life", "3");
        p.set("charging", "0");
        p.set("normal_session_cnt_in_life", "58");
        p.set("is_power_save_mode", "0");
        p.set("app_dark_mode", "0");
        p.set("screen_brightness", "40");
        p.set("battery_pct", "7");
        p.set("down_speed", "51434");
        p.set("sys_dark_mode", "0");
        p.set("font_scale", "100");
        p.set("network_type", "4");
        p.set("current_volume", "0");
        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: crate::endpoints::base::HOST_FQNOVEL.to_string(),
            path: "/reading/bookapi/plan/v".to_string(),
            params: p.to_pairs(),
            headers: dragon_read_headers(),
            ..Default::default()
        };
        Upstream::new(ctx.up.clone()).json(&spec).await
    })
}

/// The category front page (`/reading/bookapi/new_category/front/v`).
///
/// One GET returns the whole page: `data.category_tab_config.tab_list[]`,
/// each with `category_tab`/`tab_name` plus `cell_data[].atom_data[]
/// .category_data{name, pic_url, category_id}` tiles. Request shape from
/// `GetNewCategoryFrontPageRequest` (decompiled): `category_tab` is the
/// NewCategoryTabType (1=男频 by default), the rest are scene bookkeeping.
fn category_front<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let category_tab =
            crate::endpoints::util::default_val(&params.get_str("category_tab"), "1");
        let mut p = crate::endpoints::home::reading724_params();
        p.set("category_tab", category_tab);
        p.set("need_hot", "0");
        p.set("last_chose_tab", "1");
        p.set("source", "0");
        p.set("distinct_style", "0");
        p.set("new_category_tab", "1");
        p.set("sub_category_tab", "0");
        p.set("req_scene", "0");
        // v2 参数：官方 7.0.9.32 的分类页（同端点）拿到的是带 tab_list/
        // sub_tabs 的新 schema，缺这几个字段时服务端回退老结构
        // （rule.categoy_tab_dic + down_category 平铺）。
        p.set("category_tab_v2", "1");
        p.set("last_choose_tab_v2", "1");
        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: crate::endpoints::base::HOST_FQNOVEL.to_string(),
            path: "/reading/bookapi/new_category/front/v".to_string(),
            params: p.to_pairs(),
            headers: dragon_read_headers(),
            ..Default::default()
        };
        Upstream::new(ctx.up.clone()).json(&spec).await
    })
}

pub fn register(s: &mut Server) {
    s.add_route("search", handle);
    s.add_route("search_cue", search_cue);
    s.add_route("hot_search", hot_search);
    s.add_route("category_front", category_front);
}
