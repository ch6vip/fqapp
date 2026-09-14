/// Chapter previews from `/api/v1/books/{id}/chapters/summary?item_ids=`.
///
/// Note: what this endpoint actually returns, and why it is used as a preview
/// rather than an AI summary — see
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
library;

/// Upstream preview fragments can carry inline content markers, for example
/// the audio-book marker `{!-- PGC_VOICE:{...}--}` or an HTML comment, plus
/// stray HTML tags. Only the readable text belongs in the UI.
final _previewMarkerPatterns = <RegExp>[
  RegExp(r'\{!--.*?--\}', dotAll: true),
  RegExp(r'<!--.*?-->', dotAll: true),
  // A truncated audio marker whose JSON never closes: drop only the marker so
  // any readable text that follows it survives.
  RegExp(r'\{!--\s*PGC_[A-Z_]+:\{[^{}]*\}\s*-?\}?', dotAll: true),
  // Last resort for a malformed marker: drop from the marker to the end.
  RegExp(r'\{!--.*$', dotAll: true),
  RegExp(r'<!--.*$', dotAll: true),
];
final _previewTagPattern = RegExp(r'</?[a-zA-Z][^>]*>');
final _previewSpacePattern = RegExp(r'\s+');

String _cleanPreview(String raw) {
  var text = raw;
  for (final pattern in _previewMarkerPatterns) {
    text = text.replaceAll(pattern, ' ');
  }
  text = text.replaceAll(_previewTagPattern, ' ');
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  return text.replaceAll(_previewSpacePattern, ' ').trim();
}

/// Chapter preview text keyed by chapter item id.
class ChapterSummary {
  const ChapterSummary({this.byItemId = const {}});

  static const empty = ChapterSummary();

  final Map<String, String> byItemId;

  bool get isEmpty => byItemId.isEmpty;
  bool get isNotEmpty => byItemId.isNotEmpty;

  String? forItem(String itemId) {
    final text = byItemId[itemId];
    return text == null || text.isEmpty ? null : text;
  }

  static ChapterSummary fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return empty;
    final data = payload['data'];
    if (data is! Map) return empty;
    final raw = data['summary_item_data'];
    if (raw is! List) return empty;

    final byItemId = <String, String>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      final itemId = entry['item_id'] == null
          ? ''
          : '${entry['item_id']}'.trim();
      final summary = _cleanPreview(
        entry['summary'] == null ? '' : '${entry['summary']}',
      );
      if (itemId.isEmpty || summary.isEmpty) continue;
      byItemId[itemId] = summary;
    }
    if (byItemId.isEmpty) return empty;
    return ChapterSummary(byItemId: Map.unmodifiable(byItemId));
  }
}
