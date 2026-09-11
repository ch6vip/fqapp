/// Search discovery: query suggestions and hot search words.
///
/// Note: field shapes and why hot words are tolerated loosely — see
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
library;

/// One suggestion for the query being typed.
class SearchSuggestion {
  const SearchSuggestion({required this.text, this.highlighted = ''});

  /// Plain query text, usable as the search term directly.
  final String text;

  /// The same text with the matched prefix wrapped in `<em>` tags, when the
  /// upstream supplied it. Empty when only the plain form is available.
  final String highlighted;

  bool get isEmpty => text.isEmpty;

  /// Reads `query_result` (plain strings) and merges the highlight from
  /// `query_result_v2`, which is keyed by the same text.
  static List<SearchSuggestion> fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return const [];
    final data = payload['data'];
    if (data is! Map) return const [];

    final highlights = <String, String>{};
    final v2 = data['query_result_v2'];
    if (v2 is List) {
      for (final entry in v2) {
        if (entry is! Map) continue;
        final text = _string(
          entry['name'],
        ).ifEmpty(_string(entry['display_words']));
        if (text.isEmpty) continue;
        final display = entry['display_high_light'];
        if (display is List) {
          for (final item in display) {
            if (item is! Map) continue;
            final rich = _string(item['rich_text']);
            if (rich.isNotEmpty) {
              highlights[text] = rich;
              break;
            }
          }
        }
      }
    }

    final out = <SearchSuggestion>[];
    final seen = <String>{};
    final plain = data['query_result'];
    if (plain is List) {
      for (final entry in plain) {
        final text = _string(entry);
        if (text.isEmpty || !seen.add(text)) continue;
        out.add(
          SearchSuggestion(text: text, highlighted: highlights[text] ?? ''),
        );
      }
    }
    // A payload with only the v2 form still yields suggestions.
    if (out.isEmpty) {
      for (final entry in highlights.entries) {
        if (seen.add(entry.key)) {
          out.add(SearchSuggestion(text: entry.key, highlighted: entry.value));
        }
      }
    }
    return List.unmodifiable(out);
  }
}

/// The hot search board.
///
/// The payload nests the words two levels deep
/// (`data[].search_tag_data[].tag_title`) and includes cells without words, so
/// empty entries are skipped rather than surfaced.
class HotSearch {
  const HotSearch({this.words = const []});

  static const empty = HotSearch();

  final List<String> words;

  bool get isEmpty => words.isEmpty;
  bool get isNotEmpty => words.isNotEmpty;

  static HotSearch fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return empty;
    final data = payload['data'];
    if (data is! List) return empty;
    final words = <String>[];
    final seen = <String>{};
    for (final cell in data) {
      if (cell is! Map) continue;
      final tags = cell['search_tag_data'];
      if (tags is! List) continue;
      for (final tag in tags) {
        if (tag is! Map) continue;
        final title = _string(tag['tag_title']);
        if (title.isEmpty || !seen.add(title)) continue;
        words.add(title);
      }
    }
    return HotSearch(words: List.unmodifiable(words));
  }
}

String _string(dynamic value) {
  if (value == null) return '';
  if (value is List) {
    for (final entry in value) {
      final text = _string(entry);
      if (text.isNotEmpty) return text;
    }
    return '';
  }
  return '$value'.trim();
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
