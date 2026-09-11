/// Chapter previews from `/api/v1/books/{id}/chapters/summary?item_ids=`.
///
/// Note: what this endpoint actually returns, and why it is used as a preview
/// rather than an AI summary — see
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
library;

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
      final summary = entry['summary'] == null
          ? ''
          : '${entry['summary']}'.trim();
      if (itemId.isEmpty || summary.isEmpty) continue;
      byItemId[itemId] = summary;
    }
    if (byItemId.isEmpty) return empty;
    return ChapterSummary(byItemId: Map.unmodifiable(byItemId));
  }
}
