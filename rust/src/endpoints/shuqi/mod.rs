//! 书旗数据源接口：`shuqi_search` / `shuqi_book` / `shuqi_toc` / `shuqi_chapter`。
//!
//! 对应源文件 `js` 里的 `sqSearch` / `sqDetail` / `sqToc` / `sqContent`。
//! 与其余 endpoint 的区别是**不用番茄设备签名**：书旗有自己的请求加密与签名，
//! 全在 [`crate::upstream::shuqi`] 里构造，因此统一走 [`UpstreamMode::NoSign`]。
//!
//! 目录与正文都是双链路（源脚本实测结论，不是防御性冗余）：
//!
//! - 目录：H5 全量页拿真章名 → 失败才用 `chapterinfo` 递推（章名只能是占位）；
//! - 正文：免签 CDN 拿明文 → 失败才走 `chapterinfo` 加密口（要 ALG-5 解码）。
//!
//! 模块按职责拆分：[`common`] 参数与上游调用、[`search`] 搜索、[`book`] 详情、
//! [`toc`] 目录、[`content`] 正文。

mod book;
mod common;
mod content;
mod search;
mod toc;

use crate::endpoints::Server;

pub fn register(s: &mut Server) {
    s.add_route("shuqi_search", search::handle_search);
    s.add_route("shuqi_book", book::handle_book);
    s.add_route("shuqi_toc", toc::handle_toc);
    s.add_route("shuqi_chapter", content::handle_chapter);
}

#[cfg(test)]
mod tests;
