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

/// One row of the 热搜榜.
class HotSearchEntry {
  const HotSearchEntry({
    required this.title,
    this.hotValue = '',
    this.badge = '',
  });

  /// The word to search for (`tag_title`).
  final String title;

  /// 热搜值 without the trailing 「热搜值」, e.g. `183.8万`. Empty when the
  /// upstream put something else in `tag_attached` (an editorial line).
  final String hotValue;

  /// 榜单角标: 巅峰榜 / 热聊 / 霸榜 / 新 / 神作 … (`display_tag[0].text`).
  final String badge;
}

/// The hot search board.
///
/// Upstream is the 热搜榜 rank list (`search/rank_list/v`, `show_type=472`):
/// one cell with up to 50 tags, each carrying `tag_title`, `tag_attached` and
/// `display_tag`. The payload nests them two levels deep
/// (`data[].search_tag_data[]`) and can include cells without tags, so empty
/// entries are skipped rather than surfaced.
class HotSearch {
  const HotSearch({this.entries = const []});

  static const empty = HotSearch();

  final List<HotSearchEntry> entries;

  List<String> get words => [for (final entry in entries) entry.title];

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  static HotSearch fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return empty;
    final data = payload['data'];
    if (data is! List) return empty;
    final entries = <HotSearchEntry>[];
    final seen = <String>{};
    for (final cell in data) {
      if (cell is! Map) continue;
      final tags = cell['search_tag_data'];
      if (tags is! List) continue;
      for (final tag in tags) {
        if (tag is! Map) continue;
        final title = _string(tag['tag_title']);
        if (title.isEmpty || !seen.add(title)) continue;
        entries.add(
          HotSearchEntry(
            title: title,
            hotValue: _hotValue(_string(tag['tag_attached'])),
            badge: _badge(tag['display_tag']),
          ),
        );
      }
    }
    return HotSearch(entries: List.unmodifiable(entries));
  }

  /// `183.8万热搜值` -> `183.8万`; anything else stays empty rather than
  /// leaking an editorial sentence into the number column.
  static String _hotValue(String attached) {
    const suffix = '热搜值';
    if (!attached.endsWith(suffix)) return '';
    return attached.substring(0, attached.length - suffix.length).trim();
  }

  static String _badge(dynamic displayTag) {
    if (displayTag is! List) return '';
    for (final entry in displayTag) {
      if (entry is! Map) continue;
      final text = _string(entry['text']);
      if (text.isNotEmpty) return text;
    }
    return '';
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

/// The bookstore search-bar cue words (`/reading/bookapi/search/cue/v`).
///
/// The official bar rotates `data_v1[]` on a `VerticalFlipper` with the
/// response's `rotate_interval_ms` (`SearchWordDisplayView.m`); the display
/// text of one word is `display_text`/`display_text_v2`, falling back to
/// `text` (`SearchCueWord.java`).
class SearchCue {
  const SearchCue({
    this.words = const [],
    this.rotateIntervalMs = defaultIntervalMs,
  });

  /// Milliseconds one word stays on screen before the next flip.
  static const defaultIntervalMs = 5000;

  static const empty = SearchCue();

  final List<String> words;

  /// `rotate_interval_ms`; [defaultIntervalMs] when the payload carries none.
  final int rotateIntervalMs;

  bool get isEmpty => words.isEmpty;

  static SearchCue fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return empty;
    final dataV1 = payload['data_v1'];
    if (dataV1 is! List) return empty;
    final words = <String>[];
    final seen = <String>{};
    for (final entry in dataV1) {
      if (entry is! Map) continue;
      final text = _string(
        entry['display_text_v2'],
      ).ifEmpty(_string(entry['display_text'])).ifEmpty(_string(entry['text']));
      if (text.isEmpty || !seen.add(text)) continue;
      words.add(text);
    }
    if (words.isEmpty) return empty;
    final rawInterval = payload['rotate_interval_ms'];
    final interval = rawInterval is num
        ? rawInterval.toInt()
        : int.tryParse('$rawInterval') ?? 0;
    return SearchCue(
      words: List.unmodifiable(words),
      rotateIntervalMs: interval > 0 ? interval : defaultIntervalMs,
    );
  }
}
