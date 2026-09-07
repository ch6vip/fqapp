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

/// Converts an upstream chapter to plain text once, before it is cached.
/// Block elements and explicit breaks carry paragraph boundaries; inline
/// elements do not. Entity decoding belongs here, never in the reader.
String normalizeChapterText(String source) {
  final output = StringBuffer();

  void append(dom.Node node) {
    if (node is dom.Text) {
      output.write(node.data);
    } else if (node is dom.Element) {
      final tag = node.localName;
      if (_hiddenTags.contains(tag)) return;
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
