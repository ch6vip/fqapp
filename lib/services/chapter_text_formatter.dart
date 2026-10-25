import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parseFragment;

import '../models/backend_resource_url.dart';
import 'chapter_content_blocks.dart';

// The models moved out to keep the parse pipeline readable; re-export them so
// every existing `import chapter_text_formatter.dart` keeps resolving them.
export 'chapter_content_blocks.dart';

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

/// Decodes cached `<blk>` spans. Unknown shapes are dropped rather than
/// rejected: a cache written before this field existed simply has none, and the
/// reader then falls back to paragraph-level offsets.
List<ChapterBlkSpan> _blkSpansFromCache(Object? raw) {
  if (raw is! List) return const [];
  final spans = <ChapterBlkSpan>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final index = entry['e'];
    final start = entry['s'];
    final length = entry['l'];
    if (index is! int || start is! int || length is! int) continue;
    if (start < 0 || length <= 0) continue;
    spans.add(
      ChapterBlkSpan(
        elementIndex: index,
        start: start,
        length: length,
        startOffsetInPara: entry['p'] is int ? entry['p'] as int : null,
      ),
    );
  }
  return spans;
}

/// Maps the `<blk>` elements collected from raw markup onto the paragraph that
/// `flush()` actually emits.
///
/// The raw buffer is rewritten before it becomes a block — content markers are
/// stripped and whitespace trimmed — so the offsets recorded while parsing do
/// not survive. The element *text* does, so each span is located in the final
/// paragraph by walking forward from the previous one. Spans that cannot be
/// placed are dropped: the caller then falls back to paragraph-level offsets,
/// which is correct but coarser, whereas a misplaced span would highlight the
/// wrong characters.
List<ChapterBlkSpan> _remapBlkSpans(
  List<({int eIdx, int? startPos, String text})> raw,
  String paragraph,
) {
  if (raw.isEmpty || paragraph.isEmpty) return const [];
  final spans = <ChapterBlkSpan>[];
  var cursor = 0;
  for (final element in raw) {
    // Normalisation trims paragraph edges, so search for the element's trimmed
    // form — that is the part that survived.
    final needle = element.text.trim();
    if (needle.isEmpty) continue;
    final at = paragraph.indexOf(needle, cursor);
    if (at < 0) continue;
    spans.add(
      ChapterBlkSpan(
        elementIndex: element.eIdx,
        start: at,
        length: needle.length,
        startOffsetInPara: element.startPos,
      ),
    );
    cursor = at + needle.length;
  }
  return spans;
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
                if (block.blkSpans.isNotEmpty)
                  'blk': [
                    for (final span in block.blkSpans)
                      {
                        'e': span.elementIndex,
                        's': span.start,
                        'l': span.length,
                        if (span.startOffsetInPara != null)
                          'p': span.startOffsetInPara,
                      },
                  ],
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
        final blkSpans = _blkSpansFromCache(raw['blk']);
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
              blkSpans: i == 0 ? blkSpans : const [],
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
  // Rendered length of [pending] so far, used to delimit `<blk>` elements.
  int pendingLength = 0;
  final List<({int eIdx, int? startPos, int start})> blkStack = [];
  final List<({int eIdx, int? startPos, String text})> activeBlkSpans = [];

  void writePending(String value) {
    pending.write(value);
    pendingLength += value.length;
  }

  /// Closes the innermost `<blk>`, recording the text it contributed.
  ///
  /// Raw offsets do not survive the rewrite that turns [pending] into a
  /// paragraph, so the element text is kept instead and located afterwards.
  void closeBlk() {
    if (blkStack.isEmpty) return;
    final open = blkStack.removeLast();
    if (pendingLength <= open.start) return;
    final text = pending.toString().substring(open.start);
    activeBlkSpans.add((eIdx: open.eIdx, startPos: open.startPos, text: text));
  }

  void flush() {
    final paragraphs = splitChapterParagraphs(
      _stripContentMarkers(pending.toString()),
    );
    for (var i = 0; i < paragraphs.length; i++) {
      // A single upstream paragraph can split into several display paragraphs;
      // the id belongs to the first of them, but the spoken start is inherited
      // by every piece (the audio for the whole paragraph begins there).
      // `<blk>` spans were measured against the raw buffer; they only line up
      // with the emitted text when the paragraph was not split. A split
      // paragraph drops them rather than risk a misplaced highlight.
      final spans = paragraphs.length == 1
          ? _remapBlkSpans(activeBlkSpans, paragraphs[i])
          : const <ChapterBlkSpan>[];
      blocks.add(
        ChapterParagraph(
          paragraphs[i],
          paraIndex: i == 0 ? activeIndex : null,
          startMs: activeStartMs,
          blkSpans: spans,
        ),
      );
    }
    pending = StringBuffer();
    pendingLength = 0;
    blkStack.clear();
    activeBlkSpans.clear();
    // A leading break/image can flush no text. Its paragraph id still belongs
    // to the first body paragraph that is eventually emitted.
    if (paragraphs.isNotEmpty) {
      activeIndex = null;
      activeStartMs = null;
    }
  }

  void append(dom.Node node) {
    if (node is dom.Text) {
      writePending(node.data);
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
      // `<blk e_idx="N">` marks one spoken element; positionV2 addresses text
      // by (element index, offset inside it).
      final isBlk = tag == 'blk';
      if (isBlk) {
        final rawIdx = node.attributes['e_idx']?.trim();
        final rawStart = node.attributes['e_start_position']?.trim();
        blkStack.add((
          eIdx: rawIdx == null ? -1 : (int.tryParse(rawIdx) ?? -1),
          startPos: rawStart == null ? null : int.tryParse(rawStart),
          start: pendingLength,
        ));
      }
      for (final child in node.nodes) {
        append(child);
      }
      if (isBlk) closeBlk();
      if (paragraph) {
        flush();
        activeIndex = null;
        activeStartMs = null;
      }
      if (tag == 'td' || tag == 'th') writePending(' ');
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
        ? Uri.parse(resolveBackendResource(baseUrl, raw))
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
