//! REST path matching. Port of `router.go` `matchRESTPath`.
//!
//! Every request must address an endpoint through its `/api/v1/...` path; the
//! legacy `?api=<name>` query form is not honored.

use super::{Params, INTERNAL_DEVICE_PIN_KEY};

pub struct RouteMatch {
    pub api: &'static str,
    pub params: Params,
}

fn set_query_alias(q: &mut Params, target: &str, alias: &str) {
    if !q.get_str(target).is_empty() {
        return;
    }
    let v = q.get_str(alias);
    if !v.is_empty() {
        q.set(target, v);
    }
}

pub fn match_rest_path(path: &str, query: &Params) -> Option<RouteMatch> {
    let path = path.strip_suffix('/').unwrap_or(path);
    let rest = path.strip_prefix("/api/v1/")?;
    let parts: Vec<&str> = rest.split('/').collect();
    if parts.is_empty() || parts[0].is_empty() {
        return None;
    }
    let tail = &parts[1..];
    match parts[0] {
        "chapters" => match_chapters(tail, query),
        "books" => match_books(tail, query),
        "novels" => match_novels(tail, query),
        "search" => match_search(tail, query),
        "audio" => match_audio(tail, query),
        "authors" => match_authors(tail, query),
        "manga" => match_manga(tail, query),
        "videos" => match_videos(tail, query),
        "series" => match_series(tail, query),
        "recommend" => match_recommend(tail, query),
        "rank" => match_rank(tail, query),
        "articles" => match_articles(tail, query),
        "items" => match_items(tail, query),
        "comments" => match_comments(tail, query),
        "forum-id" => Some(RouteMatch {
            api: "forum_id",
            params: query.clone(),
        }),
        "viewer" => match_viewer(query),
        _ => None,
    }
}

fn match_chapters(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    match parts[0] {
        "batch" => {
            p.set("api_type", "batch");
            return Some(RouteMatch {
                api: "content",
                params: p,
            });
        }
        "full" => {
            return Some(RouteMatch {
                api: "full",
                params: p,
            })
        }
        _ => {}
    }

    let id = parts[0];
    if parts.len() == 1 {
        p.set("item_ids", id);
        return Some(RouteMatch {
            api: "content",
            params: p,
        });
    }
    match parts[1] {
        // 短剧：/api/v1/series/:id/... （官方短剧 ID 是 series id）
        "novel" => {
            p.set("item_ids", id);
            p.set("api_type", "novel");
            Some(RouteMatch {
                api: "content",
                params: p,
            })
        }
        "toutiao" => {
            p.set("item_ids", id);
            Some(RouteMatch {
                api: "toutiao",
                params: p,
            })
        }
        "timeline" => {
            p.set("item_id", id);
            Some(RouteMatch {
                api: "audio_timeline",
                params: p,
            })
        }
        "reviews" => {
            p.set("item_id", id);
            Some(RouteMatch {
                api: "idea_list",
                params: p,
            })
        }
        "paragraphs" => {
            if parts.len() >= 4 {
                p.set("item_id", id);
                p.set("para_index", parts[2]);
                match parts[3] {
                    "reviews" | "short-reviews" => Some(RouteMatch {
                        api: "idea_list",
                        params: p,
                    }),
                    _ => None,
                }
            } else {
                None
            }
        }
        _ => None,
    }
}

fn match_books(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let id = parts[0];
    let mut p = q.clone();
    p.set("book_id", id);

    if parts.len() == 1 {
        return Some(RouteMatch {
            api: "book_detail_legacy",
            params: p,
        });
    }
    match parts[1] {
        "directory" => {
            if parts.len() >= 3 {
                match parts[2] {
                    "novel" => {
                        p.set("api_type", "novel");
                        return Some(RouteMatch {
                            api: "directory",
                            params: p,
                        });
                    }
                    "fanqie" => {
                        return Some(RouteMatch {
                            api: "book",
                            params: p,
                        })
                    }
                    _ => {}
                }
            }
            Some(RouteMatch {
                api: "directory",
                params: p,
            })
        }
        "detail" => Some(RouteMatch {
            api: "book_detail_legacy",
            params: p,
        }),
        "comments" => Some(RouteMatch {
            api: "book_comments_legacy",
            params: p,
        }),
        "share" => Some(RouteMatch {
            api: "book_share",
            params: p,
        }),
        // 短剧剧评与弹幕走 `/api/v1/series/...` / `/api/v1/videos/...`，
        // 见 `match_series` / `match_videos`。
        "reviews" => Some(RouteMatch {
            api: "book_reviews",
            params: p,
        }),
        "tones" => Some(RouteMatch {
            api: "tones",
            params: p,
        }),
        "chapters" => {
            if parts.len() >= 3 && parts[2] == "summary" {
                Some(RouteMatch {
                    api: "chapter_summary",
                    params: p,
                })
            } else {
                None
            }
        }
        "related" => Some(RouteMatch {
            api: "related",
            params: p,
        }),
        _ => None,
    }
}

fn match_novels(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    p.set("post_id", parts[0]);
    Some(RouteMatch {
        api: "novel_detail",
        params: p,
    })
}

fn match_search(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    let mut p = q.clone();
    if parts.is_empty() {
        return Some(RouteMatch {
            api: "search",
            params: p,
        });
    }
    match parts[0] {
        "fanqie" => {
            p.set("search_type", "fanqie");
            set_query_alias(&mut p, "query", "q");
            Some(RouteMatch {
                api: "search",
                params: p,
            })
        }
        "suggest" => {
            set_query_alias(&mut p, "keyword", "q");
            Some(RouteMatch {
                api: "search_predict",
                params: p,
            })
        }
        "hot" => Some(RouteMatch {
            api: "hot_search",
            params: p,
        }),
        _ => None,
    }
}

fn match_audio(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    if parts[0] == "play" {
        return Some(RouteMatch {
            api: "audio_play",
            params: p,
        });
    }
    if parts[0] == "wkcontent" && parts.len() >= 2 {
        p.set("item_ids", parts[1]);
        return Some(RouteMatch {
            api: "wkcontent",
            params: p,
        });
    }
    if parts[0] == "books" && parts.len() >= 2 {
        p.set("book_id", parts[1]);
        if parts.len() == 2 {
            return Some(RouteMatch {
                api: "audio_book_detail",
                params: p,
            });
        }
        if parts.len() >= 4 && parts[2] == "chapters" {
            p.set("chapter_id", parts[3]);
            return Some(RouteMatch {
                api: "audio_chapter_info",
                params: p,
            });
        }
    }
    None
}

fn match_authors(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    p.set("author_id", parts[0]);
    if parts.len() == 1 {
        return Some(RouteMatch {
            api: "author_info",
            params: p,
        });
    }
    if parts[1] == "bookshelf" {
        return Some(RouteMatch {
            api: "author_bookshelf",
            params: p,
        });
    }
    None
}

fn match_manga(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    if parts[0] == "videos" && parts.len() >= 2 {
        p.set("pseries_id", parts[1]);
        return Some(RouteMatch {
            api: "pseries",
            params: p,
        });
    }
    p.set("item_ids", parts[0]);
    Some(RouteMatch {
        api: "manga",
        params: p,
    })
}

fn match_videos(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    if parts.len() >= 2 && parts[1] == "detail" {
        p.set("series_id", parts[0]);
        return Some(RouteMatch {
            api: "video_detail",
            params: p,
        });
    }
    // 弹幕取数以 vid 为 group_id（官方 `DanmakuRequestHelper.java:303,318`），
    // 剧集 id 只是在 business_param 里当 book_id，所以两者都进 params。
    if parts.len() >= 2 && parts[1] == "danmaku" {
        p.set("vid", parts[0]);
        // 发弹幕走 `comment/add`，与取数分开。
        if parts.len() >= 3 && parts[2] == "add" {
            p.set("mode", "danmaku");
            return Some(RouteMatch {
                api: "playlet_comment_add",
                params: p,
            });
        }
        return Some(RouteMatch {
            api: "playlet_danmaku",
            params: p,
        });
    }

    p.set("video_id", parts[0]);
    Some(RouteMatch {
        api: "video",
        params: p,
    })
}

fn match_series(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    p.set("series_id", parts[0]);
    // 短剧剧评（`gx1/m.java:168-181`）与短剧分享
    // （`m0.java:938-957`，`share_type=7`）。
    if parts.len() >= 2 {
        match parts[1] {
            // 发评论与读评论同一条上游，但本地分成两个路由：POST 的
            // `comments/add` 走写入（`comment/add/v1/`），`comments` 走列表。
            "comments" => {
                if parts.len() >= 3 && parts[2] == "add" {
                    return Some(RouteMatch {
                        api: "playlet_comment_add",
                        params: p,
                    });
                }
                return Some(RouteMatch {
                    api: "playlet_comments",
                    params: p,
                });
            }
            // 热评与右栏评论计数（`a13/w.java:563-599`）：剧集场景下
            // group_id 取 vid（调用方给），没有 vid 时退回剧集 id。
            "hot-comments" => {
                return Some(RouteMatch {
                    api: "playlet_hot_comments",
                    params: p,
                })
            }
            "share" => {
                // 官方把 seriesId 同时放在 `album_id` 与 `group_id`。
                p.set("group_id", parts[0]);
                if p.get_str("album_id").is_empty() {
                    p.set("album_id", parts[0]);
                }
                return Some(RouteMatch {
                    api: "playlet_share",
                    params: p,
                });
            }
            _ => {}
        }
    }
    Some(RouteMatch {
        api: "video_detail",
        params: p,
    })
}

fn match_recommend(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() || parts[0] == "homepage" {
        return Some(RouteMatch {
            api: "homepage_recommend",
            params: q.clone(),
        });
    }
    if parts[0] == "series-feed" {
        return Some(RouteMatch {
            api: "series_feed",
            params: q.clone(),
        });
    }
    None
}

fn match_rank(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    p.set("rank_id", parts[0]);
    Some(RouteMatch {
        api: "rank_data",
        params: p,
    })
}

fn match_articles(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    p.set("item_ids", parts[0]);
    Some(RouteMatch {
        api: "toutiao_article",
        params: p,
    })
}

fn match_items(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    p.set("item_ids", parts[0]);
    Some(RouteMatch {
        api: "item_info",
        params: p,
    })
}

fn match_comments(parts: &[&str], q: &Params) -> Option<RouteMatch> {
    if parts.is_empty() {
        return None;
    }
    let mut p = q.clone();
    // 复制链接的短链兜底（`LinkShareItem.java:86-104`）。
    if parts[0] == "short-url" {
        return Some(RouteMatch {
            api: "share_short_url",
            params: p,
        });
    }
    if parts.len() < 2 {
        return None;
    }
    p.set("comment_id", parts[0]);
    if parts[1] == "replies" {
        return Some(RouteMatch {
            api: "comment_replies",
            params: p,
        });
    }
    // 点赞/回复短剧评论（`social/t.java:803-831`、`nx1/d.java:217-231`）。
    match parts[1] {
        "digg" => Some(RouteMatch {
            api: "playlet_comment_digg",
            params: p,
        }),
        "reply" => Some(RouteMatch {
            api: "playlet_comment_reply",
            params: p,
        }),
        _ => None,
    }
}

fn match_viewer(q: &Params) -> Option<RouteMatch> {
    let plugin = q.get_str("plugin");
    if plugin.is_empty() {
        return None;
    }
    let api: &'static str = match plugin.as_str() {
        "player" => "player",
        "manga_reader" => "manga_reader",
        _ => return None,
    };
    Some(RouteMatch {
        api,
        params: q.clone(),
    })
}

/// Router-level device pinning helper (see `device_session.go`).
pub async fn pin_from_session(q: &mut Params, pool: &crate::device::DevicePool) -> Option<String> {
    let session_id = q.get_str("session_id");
    let pin = super::session::device_key_from_session(&session_id, pool).await?;
    q.set(INTERNAL_DEVICE_PIN_KEY, pin.clone());
    Some(pin)
}
