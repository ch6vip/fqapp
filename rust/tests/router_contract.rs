//! Route-table contract, ported from the reference implementation
//! `internal/endpoints/router_test.go`.
//!
//! The expected endpoint names and injected params are copied from the Go test
//! table, so this is an independent fixture rather than a Rust restatement.

use fqapi_core::endpoints::router::match_rest_path;
use fqapi_core::endpoints::Params;

fn pairs(values: &[(&str, &str)]) -> Params {
    Params::from_pairs(
        values
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
    )
}

#[test]
// The tuple is (path, pre-query, expected api, expected params); spelling it as
// a named struct would only add noise to a verbatim port of the Go table.
#[allow(clippy::type_complexity)]
fn rest_paths_match_the_go_route_table() {
    let cases: Vec<(&str, Vec<(&str, &str)>, &str, Vec<(&str, &str)>)> = vec![
        (
            "/api/v1/chapters/7276663560427471412",
            vec![],
            "content",
            vec![("item_ids", "7276663560427471412")],
        ),
        (
            "/api/v1/chapters/7173216089122439711/novel",
            vec![],
            "content",
            vec![("item_ids", "7173216089122439711"), ("api_type", "novel")],
        ),
        (
            "/api/v1/chapters/7276663560427471412/toutiao",
            vec![],
            "toutiao",
            vec![("item_ids", "7276663560427471412")],
        ),
        (
            "/api/v1/chapters/7319413832366443582/timeline",
            vec![],
            "audio_timeline",
            vec![("item_id", "7319413832366443582")],
        ),
        (
            "/api/v1/chapters/7491705434915488318/reviews",
            vec![],
            "idea_list",
            vec![("item_id", "7491705434915488318")],
        ),
        (
            "/api/v1/chapters/7491705434915488318/paragraphs/44/reviews",
            vec![],
            "idea_list",
            vec![("item_id", "7491705434915488318"), ("para_index", "44")],
        ),
        (
            "/api/v1/chapters/7491705434915488318/paragraphs/44/short-reviews",
            vec![],
            "idea_list",
            vec![("item_id", "7491705434915488318"), ("para_index", "44")],
        ),
        (
            "/api/v1/chapters/batch",
            vec![("item_ids", "1,2")],
            "content",
            vec![("item_ids", "1,2"), ("api_type", "batch")],
        ),
        (
            "/api/v1/chapters/full",
            vec![("book_id", "b"), ("item_ids", "i")],
            "full",
            vec![("book_id", "b"), ("item_ids", "i")],
        ),
        (
            "/api/v1/books/7491705400958405694",
            vec![],
            "book_detail_legacy",
            vec![("book_id", "7491705400958405694")],
        ),
        (
            "/api/v1/books/7237397843521047567/directory",
            vec![],
            "directory",
            vec![("book_id", "7237397843521047567")],
        ),
        (
            "/api/v1/books/7237397843521047567/directory/novel",
            vec![],
            "directory",
            vec![("book_id", "7237397843521047567"), ("api_type", "novel")],
        ),
        (
            "/api/v1/books/7237397843521047567/directory/fanqie",
            vec![],
            "book",
            vec![("book_id", "7237397843521047567")],
        ),
        (
            "/api/v1/books/7237397843521047567/detail",
            vec![],
            "book_detail_legacy",
            vec![("book_id", "7237397843521047567")],
        ),
        (
            "/api/v1/books/7237397843521047567/comments",
            vec![],
            "book_comments_legacy",
            vec![("book_id", "7237397843521047567")],
        ),
        (
            "/api/v1/books/6925013713007184903/share",
            vec![],
            "book_share",
            vec![("book_id", "6925013713007184903")],
        ),
        (
            "/api/v1/books/7491705400958405694/reviews",
            vec![],
            "book_reviews",
            vec![("book_id", "7491705400958405694")],
        ),
        (
            "/api/v1/books/7491705400958405694/tones",
            vec![],
            "tones",
            vec![("book_id", "7491705400958405694")],
        ),
        (
            "/api/v1/books/7491705400958405694/chapters/summary",
            vec![],
            "chapter_summary",
            vec![("book_id", "7491705400958405694")],
        ),
        (
            "/api/v1/books/7491705400958405694/related",
            vec![],
            "related",
            vec![("book_id", "7491705400958405694")],
        ),
        (
            "/api/v1/novels/7237397843521047567",
            vec![],
            "novel_detail",
            vec![("post_id", "7237397843521047567")],
        ),
        (
            "/api/v1/search",
            vec![("query", "fantasy")],
            "search",
            vec![("query", "fantasy")],
        ),
        (
            "/api/v1/search/fanqie",
            vec![("q", "修仙")],
            "search",
            vec![("query", "修仙"), ("search_type", "fanqie")],
        ),
        (
            "/api/v1/search/suggest",
            vec![("q", "fantasy")],
            "search_predict",
            vec![("keyword", "fantasy")],
        ),
        (
            "/api/v1/search/hot",
            vec![("offset", "0")],
            "hot_search",
            vec![("offset", "0")],
        ),
        (
            "/api/v1/audio/books/7491705400958405694",
            vec![],
            "audio_book_detail",
            vec![("book_id", "7491705400958405694")],
        ),
        (
            "/api/v1/audio/books/7491705400958405694/chapters/7491705434915488318",
            vec![("tone_id", "1")],
            "audio_chapter_info",
            vec![
                ("book_id", "7491705400958405694"),
                ("chapter_id", "7491705434915488318"),
            ],
        ),
        (
            "/api/v1/audio/play",
            vec![("item_ids", "i"), ("book_id", "b")],
            "audio_play",
            vec![("item_ids", "i"), ("book_id", "b")],
        ),
        (
            "/api/v1/audio/wkcontent/7276663560427471412",
            vec![("genre", "4"), ("tone_id", "99")],
            "wkcontent",
            vec![
                ("item_ids", "7276663560427471412"),
                ("genre", "4"),
                ("tone_id", "99"),
            ],
        ),
        (
            "/api/v1/authors/1988336383174046",
            vec![],
            "author_info",
            vec![("author_id", "1988336383174046")],
        ),
        (
            "/api/v1/authors/1988336383174046/bookshelf",
            vec![],
            "author_bookshelf",
            vec![("author_id", "1988336383174046")],
        ),
        (
            "/api/v1/manga/7097103732478837255",
            vec![("show_html", "0")],
            "manga",
            vec![("item_ids", "7097103732478837255")],
        ),
        (
            "/api/v1/manga/videos/7526874845758376985",
            vec![],
            "pseries",
            vec![("pseries_id", "7526874845758376985")],
        ),
        (
            "/api/v1/videos/7553551995894762521",
            vec![],
            "video",
            vec![("video_id", "7553551995894762521")],
        ),
        (
            "/api/v1/recommend/homepage",
            vec![("tab_type", "2")],
            "homepage_recommend",
            vec![("tab_type", "2")],
        ),
        (
            "/api/v1/rank/7098235271900037133",
            vec![("offset", "0")],
            "rank_data",
            vec![("rank_id", "7098235271900037133")],
        ),
        (
            "/api/v1/articles/7276663560427471412",
            vec![],
            "toutiao_article",
            vec![("item_ids", "7276663560427471412")],
        ),
        (
            "/api/v1/items/7507512821328904729,7507960973773242905",
            vec![],
            "item_info",
            vec![("item_ids", "7507512821328904729,7507960973773242905")],
        ),
        (
            "/api/v1/comments/7532767563971527448/replies",
            vec![("group_id", "g"), ("book_id", "b")],
            "comment_replies",
            vec![("comment_id", "7532767563971527448")],
        ),
        (
            "/api/v1/forum-id",
            vec![("author_user_id", "a"), ("book_id", "b"), ("item_id", "i")],
            "forum_id",
            vec![("author_user_id", "a"), ("book_id", "b"), ("item_id", "i")],
        ),
        (
            "/api/v1/viewer",
            vec![
                ("plugin", "manga_reader"),
                ("book_id", "x"),
                ("item_id", "y"),
            ],
            "manga_reader",
            vec![("plugin", "manga_reader")],
        ),
        (
            "/api/v1/viewer",
            vec![("plugin", "player"), ("book_id", "x"), ("item_id", "y")],
            "player",
            vec![("plugin", "player")],
        ),
        // trailing slash normalisation
        (
            "/api/v1/books/123/",
            vec![],
            "book_detail_legacy",
            vec![("book_id", "123")],
        ),
    ];

    for (path, pre_query, want_api, want_params) in cases {
        let m = match_rest_path(path, &pairs(&pre_query))
            .unwrap_or_else(|| panic!("path {path:?}: expected a match"));
        assert_eq!(m.api, want_api, "path {path:?}");
        for (key, want) in want_params {
            assert_eq!(
                m.params.get(key).unwrap_or(""),
                want,
                "path {path:?} param {key:?}"
            );
        }
    }
}

#[test]
fn rest_paths_that_must_not_match() {
    let misses = [
        "/",
        "/api/v1",
        "/api/v1/",
        "/api/v1/unknown-segment",
        "/api/v1/books",
        "/api/v1/manga",
        "/health",
        "/src/img.png",
        "?api=content",
        "/?api=content",
        "/api/v1/viewer",
    ];
    for path in misses {
        assert!(
            match_rest_path(path, &Params::new()).is_none(),
            "path {path:?}: expected no match"
        );
    }
}
