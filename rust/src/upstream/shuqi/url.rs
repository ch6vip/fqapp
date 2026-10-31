//! 书旗接口地址。

/// 加密口根域。
pub const HOST: &str = "https://ocean.shuqireader.com";
/// 加密口统一 UA。上游层默认值会被这个覆盖。
pub const UA: &str = "okhttp/3.12.13";

/// 加密口路径。
pub mod path {
    pub const SEARCH: &str = "/sqan/render/render/search/native_v3";
    pub const TITLEPAGE: &str = "/sqan/sqapi/bff/api/v1/reader/titlepage";
    pub const CHAPTERINFO: &str = "/sqan/sqapi/bff/api/v1/reader/chapterinfo";
}

/// H5 全量目录页（主路，一次返回整本 + 真章名）。
pub fn toc_h5_url(book_id: &str) -> String {
    format!("https://www.shuqi.com/chapter?bid={book_id}")
}

/// 免签正文缓存口。`flag`/`host` 组合由调用方枚举。
pub fn content_cdn_url(
    scheme: &str,
    host: &str,
    book_id: &str,
    chapter_id: &str,
    flag: &str,
) -> String {
    format!(
        "{scheme}://{host}/httpserver/filecache/get_book_content_{book_id}_{chapter_id}_{flag}_0_0.html"
    )
}
