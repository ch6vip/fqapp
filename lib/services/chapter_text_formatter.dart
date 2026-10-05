import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parseFragment;

const _paragraphTags = {
  'address',
  'article',
  'aside',
  'blockquote',
  'dd',
  'div',
  'dl',
  'dt',
  'figcaption',
  'figure',
  'footer',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'li',
  'main',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'tr',
  'ul',
};
const _hiddenTags = {
  'head',
  'script',
  'style',
  'template',
  'noscript',
  'title',
};
final _lineBreaks = RegExp(r'\r\n?|[\u0085\u2028\u2029]');
final _edgeMarkers = RegExp(r'^[\u200B\uFEFF]+|[\u200B\uFEFF]+$');
final _titleSpaces = RegExp(r'\s+');

/// Inline content markers that are data for other pages, never 正文. The
/// audiobook header is the loudest one: `{!-- PGC_VOICE:{...} --}` carries the
/// player's duration and upload id, and the reader used to render that raw JSON
/// as the chapter's first paragraph. The 段评 previews already drop them.
///
/// Removal is strictly line-bounded. Both the block stream (stripped one
/// paragraph at a time) and the legacy stream (stripped as one whole chapter)
/// run through [_stripContentMarkers]; a cross-line match would delete
/// different text in each, and the two streams would drift apart — taking every
/// saved text offset with them.
///
/// Unlike the previews this never drops from a stray marker to the end of the
/// chapter: a novel that quotes `<!--` as prose would lose everything after it.
final _contentMarkers = <RegExp>[
  RegExp(r'\{!--.*?--\}'),
  RegExp(r'<!--.*?-->'),
];

/// A truncated marker whose JSON never closes, for example
/// `{!-- PGC_VOICE:{"duration":"696.` with no `--}`. Upstream emits these
/// behind `<p>`, so dropping this line's tail removes the fragment.
///
/// The `PGC_` signature is required — the same one the 段评 previews match on —
/// so a stray `{!--` inside a novel's prose is left alone rather than eating the
/// rest of its line.
final _truncatedMarker = RegExp(r'\{!--\s*PGC_[A-Z_]+:[^\n]*$', multiLine: true);

String _stripContentMarkers(String text) {
  // Closed markers first: a stray unterminated `{!--` must not be allowed to
  // swallow a later, properly closed marker's trailing text.
  var out = text;
  for (final pattern in _contentMarkers) {
    out = out.replaceAll(pattern, ' ');
  }
  return out.replaceAll(_truncatedMarker, ' ');
}

/// Whether any cached paragraph still holds an inline content marker. Old
/// caches kept them as body text, so this is the precise signal that one
/// refresh would visibly improve the page.
bool _holdsContentMarker(String text) {
  for (final pattern in _contentMarkers) {
    if (pattern.hasMatch(text)) return true;
  }
  return _truncatedMarker.hasMatch(text);
}

sealed class ChapterBlock {
  const ChapterBlock();
}

class ChapterParagraph extends ChapterBlock {
  final String text;

  /// Upstream paragraph id from the `<p idx="N">` attribute.
  ///
  /// Chapter ideas (段评) are keyed by this id, so it is the only way to line a
  /// paragraph up with its comment count. Null for plain-text sources and for
  /// markup that carries no attribute.
  final int? paraIndex;

  /// Start of this paragraph's audio, in milliseconds from the beginning of the
  /// chapter, taken from the first `<span start_time="N">` inside it.
  ///
  /// Audio chapters ship the spoken timeline inline in the same markup that
  /// carries the text, so 从本段听 needs no extra request. Null for the many
  /// books without audio.
  ///
  /// Note: 段落时间轴就在正文标记里，官方与本地核心都没有独立接口 — 见
  /// .agents/notes/implemented/feature/2026-09-19-listen-from-paragraph.md
  final int? startMs;

  /// True for the `<img alt="...">` caption emitted when an image URL is
  /// unusable. It is real rendered text, but it must never be mistaken for the
  /// leading chapter title when the title is stripped.
  final bool isImageCaption;

  const ChapterParagraph(
    this.text, {
    this.paraIndex,
    this.startMs,
    this.isImageCaption = false,
  });
}

class ChapterImage extends ChapterBlock {
  final String url;
  final String alt;
  final double? width;
  final double? height;

  const ChapterImage({
    required this.url,
    this.alt = '',
    this.width,
    this.height,
  });

  double? get aspectRatio =>
      width != null && height != null ? width! / height! : null;
}

// Note: 图文缓存、旧文字锚点迁移与原始 HTML 来源见
// .agents/notes/implemented/bug-fix/2026-09-10-reader-illustrations.md
class ChapterContent {
  static const _cachePrefix = '\u001efqapp:chapter:2\n';
  static const _paragraphParserRevision = 2;

  final List<ChapterBlock> blocks;
  // Keep the exact old normalization for migrating saved text-only offsets.
  final String legacyText;
  final bool illustrationsChecked;

  /// Whether the original markup was checked for upstream paragraph ids.
  /// A checked source may legitimately contain no ids; do not keep refetching it.
  final bool paragraphIdsChecked;

  /// Whether the markup behind this text was already examined for a spoken
  /// timeline. Like [paragraphIdsChecked], a checked source may legitimately
  /// carry none — most books have no audio at all — so this only distinguishes
  /// "nothing there" from "never looked".
  final bool timelineChecked;

  ChapterContent({
    required List<ChapterBlock> blocks,
    String? legacyText,
    this.illustrationsChecked = true,
    this.paragraphIdsChecked = true,
    this.timelineChecked = true,
  }) : blocks = List.unmodifiable(blocks),
       legacyText =
           legacyText ??
           blocks.whereType<ChapterParagraph>().map((p) => p.text).join('\n');

  /// Plain text carries no markup, so there is no spoken timeline to look for
  /// and nothing worth refetching later.
  factory ChapterContent.fromPlainText(
    String text, {
    bool illustrationsChecked = false,
  }) => ChapterContent(
    blocks: [for (final p in splitChapterParagraphs(text)) ChapterParagraph(p)],
    legacyText: splitChapterParagraphs(text).join('\n'),
    illustrationsChecked: illustrationsChecked,
    paragraphIdsChecked: false,
    // Plain text carries no markup, so nothing here has been examined for a
    // timeline yet; a later illustrated fetch may still supply one.
    timelineChecked: false,
  );

  bool get isEmpty => blocks.isEmpty;
  bool get hasImages => blocks.any((block) => block is ChapterImage);
  Iterable<ChapterImage> get images => blocks.whereType<ChapterImage>();

  /// An incomplete response is useful on a cache miss, but cannot refresh a
  /// readable cached chapter: missing pictures may just mean a source outage.
  ChapterContent preferCompleteCache(ChapterContent? cached) =>
      !illustrationsChecked && cached != null && !cached.isEmpty
      ? cached
      : this;

  bool needsImageRefresh({DateTime? now}) {
    if (!illustrationsChecked) return true;
    final deadline =
        (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 + 60;
    return images.any((image) {
      int? expires;
      try {
        expires = int.tryParse(
          Uri.parse(image.url).queryParameters['x-expires'] ?? '',
        );
      } on FormatException {
        // A malformed escape (for example %FF) fails the UTF-8 query decode,
        // so treat the unusable signature as having no expiry.
        expires = null;
      }
      return expires != null && expires > 0 && expires <= deadline;
    });
  }

  /// Whether this cached chapter must be fetched once more before the page
  /// shows everything it knows how to show: missing illustrations, or body text
  /// that still holds an inline content marker.
  ///
  /// The marker check is deliberately narrow. Making every pre-timeline cache
  /// refresh would break the promise that reading a cached chapter never
  /// reaches for the network.
  bool needsRefresh({DateTime? now}) =>
      illustrationsChecked &&
          blocks.any(
            (block) =>
                block is ChapterParagraph && _holdsContentMarker(block.text),
          ) ||
      needsImageRefresh(now: now);


  ChapterContent withoutLeadingTitle(String title) {
    final wanted = title.replaceAll(_titleSpaces, '');
    // The upstream title is the first ordinary paragraph; image-alt captions
    // and standalone image blocks may precede it without shifting the match.
    // Only that leading paragraph is removed, never a later body paragraph
    // that happens to repeat the title (kept contract).
    var candidate = -1;
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (block is! ChapterParagraph) continue;
      if (block.isImageCaption) continue;
      candidate = i;
      break;
    }
    final body = [...blocks];
    var legacy = legacyText;
    if (candidate >= 0 &&
        wanted.isNotEmpty &&
        (blocks[candidate] as ChapterParagraph).text.replaceAll(
              _titleSpaces,
              '',
            ) ==
            wanted) {
      body.removeAt(candidate);
      legacy = _dropLeadingTitleParagraph(legacyText, blocks, candidate);
    }
    return ChapterContent(
      blocks: body,
      legacyText: legacy,
      illustrationsChecked: illustrationsChecked,
      paragraphIdsChecked: paragraphIdsChecked,
      timelineChecked: timelineChecked,
    );
  }

  String toCacheText() =>
      _cachePrefix +
      jsonEncode({
        'version': 2,
        'illustrationsChecked': illustrationsChecked,
        'paragraphIdsChecked': paragraphIdsChecked,
        'timelineChecked': timelineChecked,
        'paragraphParserRevision': _paragraphParserRevision,
        'legacyText': legacyText,
        'blocks': [
          for (final block in blocks)
            switch (block) {
              ChapterParagraph() => {
                'type': 'text',
                'text': block.text,
                if (block.paraIndex != null) 'idx': block.paraIndex,
                if (block.startMs != null) 'start': block.startMs,
                if (block.isImageCaption) 'caption': true,
              },
              ChapterImage() => {
                'type': 'image',
                'url': block.url,
                'alt': block.alt,
                'width': ?block.width,
                'height': ?block.height,
              },
            },
        ],
      });

  static bool isStructuredCache(String text) => text.startsWith(_cachePrefix);

  factory ChapterContent.fromCacheText(String text) {
    if (!isStructuredCache(text)) return ChapterContent.fromPlainText(text);
    final data = jsonDecode(text.substring(_cachePrefix.length));
    if (data is! Map ||
        data['version'] != 2 ||
        data['blocks'] is! List ||
        data['legacyText'] is! String ||
        data['illustrationsChecked'] is! bool) {
      throw const FormatException('章节缓存格式无效');
    }
    final blocks = <ChapterBlock>[];
    for (final raw in data['blocks'] as List) {
      if (raw is! Map) throw const FormatException('章节缓存内容无效');
      if (raw['type'] == 'text' && raw['text'] is String) {
        // Never infer upstream ids or start times from display order: titles
        // and pictures can shift it. Older caches are refreshed from source.
        final paraIndex = raw['idx'] is int ? raw['idx'] as int : null;
        final startMs = raw['start'] is int ? raw['start'] as int : null;
        final isCaption = raw['caption'] == true;
        final paragraphs = splitChapterParagraphs(raw['text'] as String);
        for (var i = 0; i < paragraphs.length; i++) {
          blocks.add(
            ChapterParagraph(
              paragraphs[i],
              paraIndex: i == 0 ? paraIndex : null,
              // A split continuation starts its spoken audio where the
              // original paragraph starts — null here would strand 从本段听
              // on the chapter opening for every piece after the first.
              startMs: startMs,
              isImageCaption: isCaption,
            ),
          );
        }
      } else if (raw['type'] == 'image' && raw['url'] is String) {
        final url = _chapterImageUrl(raw['url'] as String);
        if (url == null) throw const FormatException('章节插图地址无效');
        blocks.add(
          ChapterImage(
            url: url,
            alt: raw['alt'] is String ? raw['alt'] as String : '',
            width: _imageDimension(raw['width']),
            height: _imageDimension(raw['height']),
          ),
        );
      } else {
        throw const FormatException('章节缓存内容无效');
      }
    }
    return ChapterContent(
      blocks: blocks,
      legacyText: data['legacyText'] as String,
      illustrationsChecked: data['illustrationsChecked'] as bool,
      // Older parsers could lose ids after an empty break/image. Keep their
      // content usable offline; the reader refreshes ids only if ideas need it.
      paragraphIdsChecked:
          data['paragraphParserRevision'] == _paragraphParserRevision &&
          data['paragraphIdsChecked'] == true,
      // A cache written before this revision never recorded start times, so it
      // is refreshed once before 从本段听 can seek into it.
      timelineChecked:
          data['paragraphParserRevision'] == _paragraphParserRevision &&
          data['timelineChecked'] == true,
    );
  }
}

/// Parse upstream markup once. Cached text is decoded with fromCacheText so
/// literal tags and entities inside a novel are never interpreted a second time.
ChapterContent parseChapterContent(String source, {String? baseUrl}) {
  final blocks = <ChapterBlock>[];
  var pending = StringBuffer();
  // Upstream paragraph id currently in scope, from `<p idx="N">`.
  int? activeIndex;
  // Start of the spoken audio for the paragraph in scope, from its first
  // `<span start_time="N">`.
  int? activeStartMs;
  void flush() {
    final paragraphs = splitChapterParagraphs(
      _stripContentMarkers(pending.toString()),
    );
    for (var i = 0; i < paragraphs.length; i++) {
      // A single upstream paragraph can split into several display paragraphs;
      // the id belongs to the first of them, but the spoken start is inherited
      // by every piece (the audio for the whole paragraph begins there).
      blocks.add(
        ChapterParagraph(
          paragraphs[i],
          paraIndex: i == 0 ? activeIndex : null,
          startMs: activeStartMs,
        ),
      );
    }
    pending = StringBuffer();
    // A leading break/image can flush no text. Its paragraph id still belongs
    // to the first body paragraph that is eventually emitted.
    if (paragraphs.isNotEmpty) {
      activeIndex = null;
      activeStartMs = null;
    }
  }

  void append(dom.Node node) {
    if (node is dom.Text) {
      pending.write(node.data);
    } else if (node is dom.Element) {
      final tag = node.localName;
      if (_hiddenTags.contains(tag)) return;
      if (tag == 'img') {
        flush();
        String? url;
        for (final key in ['data-src', 'data-original', 'src']) {
          url = _chapterImageUrl(node.attributes[key], baseUrl: baseUrl);
          if (url != null) break;
        }
        final alt = node.attributes['alt']?.trim() ?? '';
        if (url != null) {
          blocks.add(
            ChapterImage(
              url: url,
              alt: alt,
              width: _imageDimension(
                node.attributes['img-width'] ??
                    node.attributes['width'] ??
                    node.attributes['data-width'],
              ),
              height: _imageDimension(
                node.attributes['img-height'] ??
                    node.attributes['height'] ??
                    node.attributes['data-height'],
              ),
            ),
          );
        } else if (alt.isNotEmpty) {
          blocks.add(ChapterParagraph(alt, isImageCaption: true));
        }
        return;
      }
      final paragraph = _paragraphTags.contains(tag);
      if (paragraph || tag == 'br' || tag == 'hr') flush();
      if (paragraph) {
        // Note: Empty flushes preserve ids only inside their own paragraph; see
        // .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md.
        activeIndex = int.tryParse(node.attributes['idx']?.trim() ?? '');
        // Cleared per paragraph so nothing leaks into the next one.
        activeStartMs = null;
      }
      if (tag == 'span' && activeStartMs == null) {
        final raw = node.attributes['start_time']?.trim();
        activeStartMs = raw == null || raw.isEmpty ? null : int.tryParse(raw);
      }
      for (final child in node.nodes) {
        append(child);
      }
      if (paragraph) {
        flush();
        activeIndex = null;
        activeStartMs = null;
      }
      if (tag == 'td' || tag == 'th') pending.write(' ');
    }
  }

  for (final node in parseFragment(source).nodes) {
    append(node);
  }
  flush();
  return ChapterContent(
    blocks: blocks,
    legacyText: normalizeChapterText(
      source,
      baseUrl: baseUrl,
      includeImageAlt: true,
    ),
  );
}

String? _chapterImageUrl(String? value, {String? baseUrl}) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return null;
  try {
    final uri = Uri.parse(raw);
    final resolved = uri.hasScheme
        ? uri
        : baseUrl != null
        ? Uri.parse(baseUrl).resolveUri(uri)
        : null;
    if (resolved == null ||
        (resolved.scheme != 'https' && resolved.scheme != 'http') ||
        resolved.host.isEmpty ||
        resolved.userInfo.isNotEmpty) {
      return null;
    }
    // Re-encoding an absolute signed CDN URL can invalidate its signature.
    return uri.hasScheme ? raw : resolved.toString();
  } on FormatException {
    return null;
  }
}

double? _imageDimension(Object? value) {
  final dimension = double.tryParse(value?.toString() ?? '');
  return dimension != null &&
          dimension.isFinite &&
          dimension > 0 &&
          dimension <= 100000
      ? dimension
      : null;
}

/// Converts an upstream chapter to plain text once, before it is cached.
/// Block elements and explicit breaks carry paragraph boundaries; inline
/// elements do not. Entity decoding belongs here, never in the reader.
/// Removes the legacy paragraph that corresponds to the leading title block
/// [candidate] from [text]. Image-alt captions and standalone images may precede
/// it; counting the legacy paragraphs they contribute locates the title without
/// ever deleting a later body paragraph that merely repeats the title.
String _dropLeadingTitleParagraph(
  String text,
  List<ChapterBlock> blocks,
  int candidate,
) {
  final paragraphs = [...splitChapterParagraphs(text)];
  var offset = 0;
  for (var i = 0; i < candidate; i++) {
    final block = blocks[i];
    if (block is ChapterParagraph) {
      offset += splitChapterParagraphs(block.text).length;
    }
  }
  final candidateText = (blocks[candidate] as ChapterParagraph).text.replaceAll(
    _titleSpaces,
    '',
  );
  if (offset >= paragraphs.length ||
      paragraphs[offset].replaceAll(_titleSpaces, '') != candidateText) {
    // The legacy stream cannot be aligned with the block stream (for example
    // an inline image split one paragraph); leave it untouched rather than
    // deleting an unrelated line.
    return text;
  }
  paragraphs.removeAt(offset);
  return paragraphs.join('\n');
}

String normalizeChapterText(
  String source, {
  String? baseUrl,
  bool includeImageAlt = false,
}) {
  final output = StringBuffer();

  void append(dom.Node node) {
    if (node is dom.Text) {
      output.write(node.data);
    } else if (node is dom.Element) {
      final tag = node.localName;
      if (_hiddenTags.contains(tag)) return;
      if (tag == 'img') {
        if (includeImageAlt) {
          String? url;
          for (final key in ['data-src', 'data-original', 'src']) {
            url = _chapterImageUrl(node.attributes[key], baseUrl: baseUrl);
            if (url != null) break;
          }
          final alt = node.attributes['alt']?.trim() ?? '';
          if (url == null && alt.isNotEmpty) {
            output.write('\n');
            output.write(alt);
            output.write('\n');
          }
        }
        return;
      }
      final paragraph = _paragraphTags.contains(tag);
      if (paragraph || tag == 'br' || tag == 'hr') output.write('\n');
      for (final child in node.nodes) {
        append(child);
      }
      if (paragraph) output.write('\n');
      if (tag == 'td' || tag == 'th') output.write(' ');
    }
  }

  for (final node in parseFragment(source).nodes) {
    append(node);
  }
  return splitChapterParagraphs(
    _stripContentMarkers(output.toString()),
  ).join('\n');
}

/// Splits plain text from either the network or an existing offline cache.
/// Soft line wrapping and the two-character first-line indent are display
/// concerns, so cached text keeps its content and internal spacing intact.
List<String> splitChapterParagraphs(String text, {String chapterTitle = ''}) {
  final paragraphs = text
      .replaceAll(_lineBreaks, '\n')
      .replaceAll('\u00A0', ' ')
      .split('\n')
      .map((line) => line.trim().replaceAll(_edgeMarkers, '').trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (chapterTitle.trim().isNotEmpty &&
      paragraphs.isNotEmpty &&
      paragraphs.first.replaceAll(_titleSpaces, '') ==
          chapterTitle.replaceAll(_titleSpaces, '')) {
    paragraphs.removeAt(0);
  }
  return List.unmodifiable(paragraphs);
}
