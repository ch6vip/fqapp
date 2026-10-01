/// Rich book metadata from the reading-API detail endpoint
/// (`/api/v1/books/{id}/detail`, upstream `/reading/bookapi/detail/v`).
///
/// Note: 为何复用详情响应而不是新增请求、以及「数值字段全是字符串」的契约 — 见
/// .agents/notes/implemented/feature/2026-09-10-detail-audio-replica.md
///
/// The upstream payload is a 200-field `BookInfo` object whose numeric fields
/// are **strings** (`word_number: "1328318"`, `creation_status: "0"`), so every
/// value is read defensively. Field names and semantics were verified against
/// the official client's own `com.dragon.read.api.bookapi.BookInfo` model and
/// against live responses.
library;

/// One entry of the book's rank history (`book_rank_info`).
class BookRankInfo {
  const BookRankInfo({required this.text, this.url = ''});

  final String text;
  final String url;

  bool get isEmpty => text.trim().isEmpty;

  static BookRankInfo? fromRaw(dynamic raw) {
    if (raw is! Map) return null;
    final text = _string(raw['text']);
    if (text.isEmpty) return null;
    return BookRankInfo(text: text, url: _string(raw['url']));
  }
}

/// The book's author, as shown in the author row of the detail page.
class BookAuthor {
  const BookAuthor({
    this.name = '',
    this.id = '',
    this.avatar = '',
    this.title = '',
    this.canFollow = false,
  });

  final String name;
  final String id;
  final String avatar;

  /// The level badge supplied by the upstream as `title_text`, e.g. `作家Lv.5`.
  final String title;
  final bool canFollow;

  bool get isEmpty => name.isEmpty;

  static BookAuthor fromRaw(dynamic raw) {
    if (raw is! Map) return const BookAuthor();
    // `user_title_infos` is a list of {title, title_text}; the human-readable
    // badge is `title_text` (e.g. author_level_5 -> 作家Lv.5).
    var title = '';
    final titles = raw['user_title_infos'];
    if (titles is List) {
      for (final entry in titles) {
        if (entry is! Map) continue;
        final text = _string(entry['title_text']);
        if (text.isNotEmpty) {
          title = text;
          break;
        }
      }
    }
    if (title.isEmpty) title = _string(raw['author_role']);
    return BookAuthor(
      name: _string(raw['user_name']),
      id: _string(raw['user_id']),
      avatar: _string(raw['user_avatar']),
      title: title,
      canFollow: raw['can_follow'] == true,
    );
  }
}

/// Normalized book detail used by the detail page.
class BookDetail {
  const BookDetail({
    this.bookId = '',
    this.title = '',
    this.author = const BookAuthor(),
    this.abstract = '',
    this.cover = '',
    this.category = '',
    this.creationStatus = -1,
    this.wordNumber = 0,
    this.serialCount = 0,
    this.readCount = '',
    this.readCountAll = '',
    this.score = '',
    this.tags = const [],
    this.original = false,
    this.subInfo = '',
    this.lastChapterTitle = '',
    this.rankTitle = '',
    this.rank = const [],
    this.source = '',
  });

  final String bookId;
  final String title;
  final BookAuthor author;
  final String abstract;
  final String cover;

  /// Primary genre, e.g. `都市脑洞`. Usually the first entry of [tags].
  final String category;

  /// `0` finished, `1` serializing, `4` update stopped, `-1` unknown.
  final int creationStatus;
  final int wordNumber;
  final int serialCount;

  /// Raw upstream counters. [readCount] is a plain number (`"79528"`) and is
  /// formatted for display; [subInfo] may already be a display string such as
  /// `8万人在读` and takes precedence when present.
  final String readCount;
  final String readCountAll;

  /// Rating on a 0-10 scale, e.g. `8.9`. Empty when the book has no rating.
  final String score;

  final List<String> tags;

  /// `authorize_type == "1"` marks an original 番茄 work.
  final bool original;
  final String subInfo;
  final String lastChapterTitle;
  final String rankTitle;
  final List<BookRankInfo> rank;
  final String source;

  bool get isEmpty => bookId.isEmpty && title.isEmpty;

  /// Whether any of the extra metadata the redesigned hero shows is present.
  bool get hasMeta =>
      category.isNotEmpty ||
      statusLabel.isNotEmpty ||
      wordLabel.isNotEmpty ||
      original;

  bool get finished => creationStatus == 0;

  String get statusLabel => switch (creationStatus) {
    0 => '完结',
    1 => '连载中',
    4 => '停更',
    _ => '',
  };

  String get wordLabel => formatWordCount(wordNumber);

  /// Reading counter for the stats row. Prefers the upstream's own display
  /// string, otherwise formats the raw count.
  String get readLabel {
    final formatted = formatCounter(readCount);
    if (formatted.isNotEmpty) return formatted;
    return subInfo;
  }

  double? get scoreValue {
    final value = double.tryParse(score.trim());
    if (value == null || value <= 0 || value > 10) return null;
    return value;
  }

  /// Score rendered with one decimal (`9.3`), matching the upstream format.
  String get scoreLabel {
    final value = scoreValue;
    if (value == null) return '';
    return value.toStringAsFixed(1);
  }

  /// Category · status · word count, in the order the official page shows.
  List<String> get metaParts => [
    if (category.isNotEmpty) category,
    if (statusLabel.isNotEmpty) statusLabel,
    if (wordLabel.isNotEmpty) wordLabel,
  ];

  /// Reads the detail response. Accepts the `{code, data}` bridge envelope, a
  /// nested `data.data` wrapper, or the bare object.
  static BookDetail fromPayload(Map<String, dynamic> payload) {
    final data = resolveDetailData(payload);
    if (data == null) return const BookDetail();
    final tags = _splitTags(data['tags']);
    final category = _string(data['category']);
    return BookDetail(
      bookId: _string(data['book_id']),
      title: _string(data['book_name']),
      author: BookAuthor.fromRaw(data['author_info']).name.isEmpty
          ? _fallbackAuthor(data)
          : BookAuthor.fromRaw(data['author_info']),
      abstract: _string(data['abstract']),
      cover: _string(
        data['detail_page_thumb_url'],
      ).ifEmpty(_string(data['thumb_url'])),
      category: category.isEmpty && tags.isNotEmpty ? tags.first : category,
      creationStatus: _int(data['creation_status'], fallback: -1),
      wordNumber: _int(data['word_number']),
      serialCount: _int(
        data['serial_count'],
        fallback: _int(data['content_chapter_number']),
      ),
      readCount: _string(data['read_count']),
      readCountAll: _string(data['read_count_all']),
      score: _string(data['score']),
      tags: tags,
      original: _string(data['authorize_type']) == '1',
      subInfo: _string(data['sub_info']),
      lastChapterTitle: _string(data['last_chapter_title']),
      rankTitle: _string(data['rank_title']),
      rank: _rankList(data['book_rank_info']),
      source: _string(data['source']),
    );
  }

  /// Without `author_info` the top-level `author_id` is the only identity
  /// hint, but it is namespaced: `2_` novel authors resolve on
  /// `/reading/user/basic_info/get/v` while `1_` manga/manju authors do not —
  /// the service answers CALL_SERVICE_FAIL for them, and the bare numeric
  /// part resolves to a placeholder non-author user. Both leave the author
  /// home a dead end, so manga/manju keeps the display name only.
  // Note: 上游对未知裸数字伪造占位用户、对 1_ 报 CALL_SERVICE_FAIL —
  // 见 .agents/notes/implemented/bug-fix/2026-10-01-manga-author-id-namespace.md
  static BookAuthor _fallbackAuthor(Map<String, dynamic> data) {
    final id = _string(data['author_id']);
    return BookAuthor(
      name: _string(data['author']),
      id: id.startsWith('1_') ? '' : id,
    );
  }
}

/// Unwraps the detail envelope down to the object that holds the book fields.
Map<String, dynamic>? resolveDetailData(Map<String, dynamic> payload) {
  dynamic data = payload['data'] ?? payload;
  // Some bridges wrap the upstream payload one level deeper.
  if (data is Map && data['data'] is Map) data = data['data'];
  if (data is! Map) return null;
  return Map<String, dynamic>.from(data);
}

/// Formats a character count as the official client does:
/// `1328318 -> 132.8万字`, `130000000 -> 1.3亿字`.
String formatWordCount(int words) {
  if (words <= 0) return '';
  if (words < 10000) return '$words字';
  if (words < 100000000) return '${_trim(words / 10000)}万字';
  return '${_trim(words / 100000000)}亿字';
}

/// Formats a raw counter (`"79528"`) as `7.9万`, `5252634` as `525.3万`,
/// and returns the input unchanged when it is not a plain number (some
/// upstream fields already carry a display string such as `8万人在读`).
String formatCounter(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  final value = int.tryParse(text);
  if (value == null) return text;
  if (value < 10000) return '$value';
  if (value < 100000000) return '${_trim(value / 10000)}万';
  return '${_trim(value / 100000000)}亿';
}

/// One decimal place, dropping a trailing `.0` so `31.0万` prints as `31万`.
String _trim(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

List<String> _splitTags(dynamic raw) {
  final text = _string(raw);
  if (text.isEmpty) return const [];
  return List.unmodifiable([
    for (final part in text.split(RegExp('[,，]')))
      if (part.trim().isNotEmpty) part.trim(),
  ]);
}

List<BookRankInfo> _rankList(dynamic raw) {
  if (raw is! List) return const [];
  final ranks = <BookRankInfo>[];
  for (final entry in raw) {
    final rank = BookRankInfo.fromRaw(entry);
    if (rank != null) ranks.add(rank);
  }
  return List.unmodifiable(ranks);
}

String _string(dynamic value) => value == null ? '' : '$value'.trim();

int _int(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
