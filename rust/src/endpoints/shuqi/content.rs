//! 书旗正文：免签 CDN 主路 + `chapterinfo` 加密口兜底。

use std::future::Future;
use std::time::{Duration, Instant};

use futures::future::BoxFuture;
use futures::stream::{FuturesUnordered, StreamExt};
use serde_json::{json, Value};

use crate::endpoints::{Ctx, Params};
use crate::error::{ApiError, ApiResult};
use crate::upstream::shuqi as proto;

use super::common::{browser_headers, get_text, post_enc, resolve_book_id, resolve_chapter_id};

/// 免签 CDN 的 host 与 flag 组合（源脚本实测「两个 host × 两个 flag」）。
const CDN_HOSTS: [&str; 2] = ["c1.shuqireader.com", "c2.shuqireader.com"];
const CDN_FLAGS: [&str; 2] = ["3111111111", "2111111111"];

/// 单次 CDN 探测的限时。上游传输层默认 15s，串行 8 次最坏 120s，远超 Dart
/// 侧 20s 的请求超时，chapterinfo 兜底根本来不及执行。
const CDN_ATTEMPT_TIMEOUT: Duration = Duration::from_secs(4);

/// 正文获取的总预算（CDN 两轮 + chapterinfo 兜底）。
///
/// 两轮 CDN 各 4s、chapterinfo 再占满 15s 的传输超时，串行最坏 23s，会先
/// 撞上 Dart 侧 20s 的请求超时。预算用尽后跳过剩余步骤，把已收集的错误带回。
const CONTENT_BUDGET: Duration = Duration::from_secs(15);

/// 预算剩余时长；用尽时返回 None，调用方跳过剩余步骤。
fn budget_left(started: Instant, budget: Duration) -> Option<Duration> {
    let left = budget.checked_sub(started.elapsed())?;
    (!left.is_zero()).then_some(left)
}

/// 并发跑一轮探测：每个尝试独立限时，首个成功立即返回；全部失败时按完成
/// 顺序带回各条错误（`label: reason`），供最终错误信息拼接。
pub(super) async fn first_ok<T, F>(
    attempts: Vec<(String, F)>,
    timeout: Duration,
) -> Result<T, Vec<String>>
where
    F: Future<Output = ApiResult<T>>,
{
    let mut pending = FuturesUnordered::new();
    for (label, attempt) in attempts {
        pending.push(async move {
            match tokio::time::timeout(timeout, attempt).await {
                Ok(Ok(value)) => Ok(value),
                Ok(Err(err)) => Err(format!("{label}: {err}")),
                Err(_) => Err(format!("{label}: timed out after {timeout:?}")),
            }
        });
    }
    let mut errors = Vec::new();
    while let Some(done) = pending.next().await {
        match done {
            Ok(value) => return Ok(value),
            Err(err) => errors.push(err),
        }
    }
    Err(errors)
}

/// 免签 CDN 一轮：2 host × 2 flag 并发探测，命中即返回；全失败时带回每条错误。
/// `attempt_timeout` 是单次探测的剩余预算，由调用方按总时限裁短。
async fn cdn_round(
    ctx: &Ctx,
    scheme: &str,
    bid: &str,
    cid: &str,
    attempt_timeout: Duration,
) -> Result<String, Vec<String>> {
    let mut attempts = Vec::new();
    for host in CDN_HOSTS {
        for flag in CDN_FLAGS {
            let url = proto::content_cdn_url(scheme, host, bid, cid, flag);
            let target = url.clone();
            attempts.push((url, async move {
                let body = get_text(ctx, &target, browser_headers()).await?;
                proto::parse_cdn_payload(&body)
                    .ok_or_else(|| ApiError::Internal("cdn response carried no content".into()))
            }));
        }
    }
    first_ok(attempts, attempt_timeout).await
}

/// `chapterinfo` 加密口：返回 base64，需要 ALG-5 解码。
async fn chapterinfo_payload(
    ctx: &Ctx,
    bid: &str,
    cid: &str,
    left: Duration,
    budget: Duration,
    cdn_note: &str,
) -> ApiResult<Value> {
    let payload = match tokio::time::timeout(
        left,
        post_enc(
            ctx,
            proto::path::CHAPTERINFO,
            &[("bookId", bid), ("chapterId", cid)],
            Some(proto::CI_UID),
        ),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => {
            return Err(ApiError::Internal(format!(
                "shuqi content unavailable for book {bid} chapter {cid}: \
                 chapterinfo exceeded the {budget:?} budget; {cdn_note}"
            )));
        }
    }
    .map_err(|err| {
        ApiError::Internal(format!(
            "shuqi content unavailable for book {bid} chapter {cid}: {err}; {cdn_note}"
        ))
    })?;
    let encoded = payload
        .get("data")
        .and_then(|d| d.get("chapter"))
        .and_then(|c| c.get("content"))
        .and_then(|c| c.as_str())
        .unwrap_or("");
    if encoded.is_empty() {
        return Err(ApiError::Internal(format!(
            "shuqi content missing for book {bid} chapter {cid}; {cdn_note}"
        )));
    }
    let text = proto::decode_content(encoded);
    if text.trim().is_empty() {
        return Err(ApiError::Internal(format!(
            "shuqi content decoded empty for book {bid} chapter {cid}; {cdn_note}"
        )));
    }

    Ok(json!({
        "source": "shuqi",
        "data": { "path": "chapterinfo", "bookId": bid, "chapterId": cid, "content": text }
    }))
}

/// 正文获取的主流程：CDN 两轮 → chapterinfo 兜底，整体受 `budget` 约束。
///
/// 预算在步骤之间检查：用尽时跳过剩余步骤，并在错误里带回已收集的 CDN 原因，
/// 避免整条链路跑过 Dart 侧的请求超时。
pub(super) async fn chapter_payload(
    ctx: &Ctx,
    bid: &str,
    cid: &str,
    budget: Duration,
) -> ApiResult<Value> {
    let started = Instant::now();
    // ① 免签 CDN：明文，原脚本只走 http；这里 http 全轮失败再补一轮 https，
    //    以适配禁用明文流量的平台。每轮内并发探测、单次短超时，避免串行
    //    8 次 15s 把 Dart 侧的请求预算耗尽。
    let mut cdn_errors: Vec<String> = Vec::new();
    for scheme in ["http", "https"] {
        let Some(left) = budget_left(started, budget) else {
            break;
        };
        match cdn_round(ctx, scheme, bid, cid, left.min(CDN_ATTEMPT_TIMEOUT)).await {
            Ok(text) => {
                return Ok(json!({
                    "source": "shuqi",
                    "data": { "path": "cdn", "bookId": bid, "chapterId": cid, "content": text }
                }));
            }
            Err(mut errors) => cdn_errors.append(&mut errors),
        }
    }
    let cdn_note = if cdn_errors.is_empty() {
        "cdn attempts: none".to_string()
    } else {
        format!("cdn attempts: {}", cdn_errors.join("; "))
    };

    // ② chapterinfo 加密口：预算用尽就不再发起，直接用已收集的错误收尾。
    let Some(left) = budget_left(started, budget) else {
        return Err(ApiError::Internal(format!(
            "shuqi content unavailable for book {bid} chapter {cid}: \
             {budget:?} budget exhausted before chapterinfo; {cdn_note}"
        )));
    };
    chapterinfo_payload(ctx, bid, cid, left, budget, &cdn_note).await
}

pub(super) fn handle_chapter<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let bid = resolve_book_id(params)?;
        let cid = resolve_chapter_id(params)?;
        chapter_payload(ctx, &bid, &cid, CONTENT_BUDGET).await
    })
}
