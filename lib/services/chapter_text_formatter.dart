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

  /// True for the `<img alt="...">` caption emitted when an image URL is
  /// unusable. It is real rendered text, but it must never be mistaken for the
  /// leading chapter title when the title is stripped.
  final bool isImageCaption;

  const ChapterParagraph(
    this.text, {
    this.paraIndex,
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

  final List<ChapterBlock> blocks;
  // Keep the exact old normalization for migrating saved text-only offsets.
  final String legacyText;
  final bool illustrationsChecked;

  /// Whether the original markup was checked for upstream paragraph ids.
  /// A checked source may legitimately contain no ids; do not keep refetching it.
  final bool paragraphIdsChecked;

  ChapterContent({
    required List<ChapterBlock> blocks,
    String? legacyText,
    this.illustrationsChecked = true,
    this.paragraphIdsChecked = true,
  }) : blocks = List.unmodifiable(blocks),
       legacyText =
           legacyText ??
           blocks.whereType<ChapterParagraph>().map((p) => p.text).join('\n');

  factory ChapterContent.fromPlainText(
    String text, {
    bool illustrationsChecked = false,
  }) => ChapterContent(
    blocks: [for (final p in splitChapterParagraphs(text)) ChapterParagraph(p)],
    legacyText: splitChapterParagraphs(text).join('\n'),
    illustrationsChecked: illustrationsChecked,
    paragraphIdsChecked: false,
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
    );
  }

  String toCacheText() =>
      _cachePrefix +
      jsonEncode({
        'version': 2,
        'illustrationsChecked': illustrationsChecked,
        'paragraphIdsChecked': paragraphIdsChecked,
        'legacyText': legacyText,
        'blocks': [
          for (final block in blocks)
            switch (block) {
              ChapterParagraph() => {
                'type': 'text',
                'text': block.text,
                if (block.paraIndex != null) 'idx': block.paraIndex,
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
        // Never infer upstream ids from display order: titles and pictures can
        // shift it. Older caches without ids can be refreshed from the source.
        final paraIndex = raw['idx'] is int ? raw['idx'] as int : null;
        final isCaption = raw['caption'] == true;
        final paragraphs = splitChapterParagraphs(raw['text'] as String);
        for (var i = 0; i < paragraphs.length; i++) {
          blocks.add(
            ChapterParagraph(
              paragraphs[i],
              paraIndex: i == 0 ? paraIndex : null,
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
      paragraphIdsChecked: data['paragraphIdsChecked'] is bool
          ? data['paragraphIdsChecked'] as bool
          : blocks.whereType<ChapterParagraph>().any(
              (p) => p.paraIndex != null,
            ),
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
  void flush() {
    final paragraphs = splitChapterParagraphs(pending.toString());
    for (var i = 0; i < paragraphs.length; i++) {
      // A single upstream paragraph can split into several display paragraphs;
      // the id belongs to the first of them.
      blocks.add(
        ChapterParagraph(paragraphs[i], paraIndex: i == 0 ? activeIndex : null),
      );
    }
    pending = StringBuffer();
    activeIndex = null;
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
        final attribute = int.tryParse(node.attributes['idx']?.trim() ?? '');
        if (attribute != null) activeIndex = attribute;
      }
      for (final child in node.nodes) {
        append(child);
      }
      if (paragraph) flush();
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
  return splitChapterParagraphs(output.toString()).join('\n');
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
