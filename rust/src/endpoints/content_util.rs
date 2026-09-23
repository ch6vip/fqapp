//! HTML cleanup shared by the content / full / manga / toutiao endpoints.
//! Port of `/internal/endpoints/content_util.go`.

use once_cell::sync::Lazy;
use regex::Regex;

static CONTENT_STRIP_PATTERNS: Lazy<Vec<Regex>> = Lazy::new(|| {
    [
        r#"<p class="pictureDesc" group-id="\d+" idx="\d+">"#,
        r"</body>|</html>|</div>",
        r#"<p class="picture" group-id="\d+">"#,
        r#"<div data-fanqie-type="image" source="user">"#,
        r"(?s)<head>.*</h1>",
        r"(?s)<!DOCTYPE.*<html>",
        r"(?s)<\?xml.*\?>",
        r#"<p idx="\d+">"#,
        r"(?s)<header>.*</header>",
        r"<article>|</article>",
        r"<footer>|</footer>",
        r"(?s)<tt_keyword.*keyword_ad>",
        r"<p>",
    ]
    .iter()
    .map(|p| Regex::new(p).expect("strip pattern"))
    .collect()
});

static AMP_X_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"&amp;x").unwrap());
static CLOSE_P_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"</p>").unwrap());

pub struct FullContentProcessor {
    br: Regex,
    open_p: Regex,
    close_p: Regex,
    any_tag: Regex,
    multi_nl: Regex,
}

impl Default for FullContentProcessor {
    fn default() -> Self {
        Self::new()
    }
}

impl FullContentProcessor {
    pub fn new() -> Self {
        FullContentProcessor {
            br: Regex::new(r"(?i)<\s*br\s*/?>").unwrap(),
            open_p: Regex::new(r"(?i)<\s*p[^>]*>").unwrap(),
            close_p: Regex::new(r"(?i)<\s*/p\s*>").unwrap(),
            any_tag: Regex::new(r"<[^>]*>").unwrap(),
            multi_nl: Regex::new(r"\n{2,}").unwrap(),
        }
    }

    /// Converts br/p tags to newlines, strips remaining tags, applies the
    /// shared strip patterns, collapses repeated newlines, and trims.
    pub fn process(&self, content: &str) -> String {
        let c = self.br.replace_all(content, "\n");
        let c = self.open_p.replace_all(&c, "\n");
        let c = self.close_p.replace_all(&c, "\n");
        let c = self.any_tag.replace_all(&c, "");
        let mut c = c.into_owned();
        for re in CONTENT_STRIP_PATTERNS.iter() {
            c = re.replace_all(&c, "").into_owned();
        }
        c = AMP_X_RE.replace_all(&c, "&x").into_owned();
        c = self.multi_nl.replace_all(&c, "\n").into_owned();
        c.trim().to_string()
    }
}

/// `processFullContent` as a free function.
pub fn process_full_content(content: &str) -> String {
    FullContentProcessor::new().process(content)
}

/// `processContentPatterns`.
pub fn process_content_patterns(content: &str) -> String {
    let mut c = content.to_string();
    for re in CONTENT_STRIP_PATTERNS.iter() {
        c = re.replace_all(&c, "").into_owned();
    }
    c = AMP_X_RE.replace_all(&c, "&x").into_owned();
    c = CLOSE_P_RE.replace_all(&c, "\n").into_owned();
    c.trim().to_string()
}
