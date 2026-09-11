/// Book review entries from `/api/v1/books/{id}/comments`
/// (upstream `/reading/ugc/novel_comment/book/v/`).
///
/// Verified live shape: `data.comment[]` entries carry `text` (not `content`),
/// an integer `score` on a **0-10** scale, `digg_count`, `reply_count`,
/// `read_duration` in seconds, and a nested `user_info`. Page-level counters
/// live next to the list: `comment_cnt` (total reviews) and `context`
/// (a ready-made `2.6万人点评` label).
library;

/// One book review.
class BookComment {
  const BookComment({
    this.id = '',
    this.text = '',
    this.score = 0,
    this.diggCount = 0,
    this.replyCount = 0,
    this.readSeconds = 0,
    this.createdAt,
    this.userName = '',
    this.userAvatar = '',
    this.isAuthor = false,
  });

  final String id;
  final String text;

  /// Upstream rating on a 0-10 scale.
  final int score;
  final int diggCount;
  final int replyCount;

  /// How long the reviewer had read the book, in seconds.
  final int readSeconds;
  final DateTime? createdAt;
  final String userName;
  final String userAvatar;
  final bool isAuthor;

  /// Upstream scores are 0-10; the五角星 row shows halves of that.
  double get stars => (score.clamp(0, 10)) / 2;

  bool get isEmpty => text.trim().isEmpty;

  /// Relative publish time (`1天前`), matching the official list.
  String relativeTime({DateTime? now}) {
    final created = createdAt;
    if (created == null) return '';
    final reference = now ?? DateTime.now();
    final seconds = reference.difference(created).inSeconds;
    if (seconds < 0) return '刚刚';
    if (seconds < 60) return '刚刚';
    if (seconds < 3600) return '${seconds ~/ 60}分钟前';
    if (seconds < 86400) return '${seconds ~/ 3600}小时前';
    if (seconds < 86400 * 30) return '${seconds ~/ 86400}天前';
    if (seconds < 86400 * 365) return '${seconds ~/ (86400 * 30)}个月前';
    return '${seconds ~/ (86400 * 365)}年前';
  }

  /// `阅读14小时后点评` style caption, omitted when the reader did not read.
  String get readDurationLabel {
    if (readSeconds <= 0) return '';
    final hours = readSeconds ~/ 3600;
    if (hours >= 1) return '阅读$hours小时后点评';
    final minutes = readSeconds ~/ 60;
    if (minutes >= 1) return '阅读$minutes分钟后点评';
    return '阅读$readSeconds秒后点评';
  }

  static BookComment? fromRaw(dynamic raw) {
    if (raw is! Map) return null;
    final text = _string(raw['text']);
    if (text.isEmpty) return null;
    final user = raw['user_info'];
    final userMap = user is Map ? user : const {};
    return BookComment(
      id: _string(raw['comment_id']),
      text: text,
      score: _int(raw['score']),
      diggCount: _int(raw['digg_count']),
      replyCount: _int(raw['reply_count']),
      readSeconds: _int(raw['read_duration']),
      createdAt: _timestamp(raw['create_timestamp']),
      userName: _string(userMap['user_name']),
      userAvatar: _string(userMap['user_avatar']),
      isAuthor: userMap['is_author'] == true,
    );
  }
}

/// A page of reviews plus the counters the detail page header shows.
class BookCommentPage {
  const BookCommentPage({
    this.comments = const [],
    this.totalCount = 0,
    this.scoreCount = 0,
    this.scoreContext = '',
    this.hasMore = false,
    this.nextOffset = 0,
  });

  final List<BookComment> comments;

  /// `comment_cnt`: total number of reviews.
  final int totalCount;

  /// `score_cnt`: number of users who left a rating.
  final int scoreCount;

  /// `context`: upstream display string such as `2.6万人点评`.
  final String scoreContext;
  final bool hasMore;
  final int nextOffset;

  bool get isEmpty => comments.isEmpty;

  /// Header label: `书评 · 24364`, or just `书评` when the count is unknown.
  String get headerLabel => totalCount > 0 ? '书评 · $totalCount' : '书评';

  /// Reviews labelled with the ready-made upstream string when present.
  String get scoreLabel {
    if (scoreContext.isNotEmpty) return scoreContext;
    if (scoreCount > 0) return '${formatCount(scoreCount)}人点评';
    return '';
  }

  static BookCommentPage fromPayload(Map<String, dynamic> payload) {
    final data = resolveCommentData(payload);
    if (data == null) return const BookCommentPage();
    final raw = data['comment'];
    final comments = <BookComment>[];
    if (raw is List) {
      for (final entry in raw) {
        final comment = BookComment.fromRaw(entry);
        if (comment != null) comments.add(comment);
      }
    }
    return BookCommentPage(
      comments: List.unmodifiable(comments),
      totalCount: _int(data['comment_cnt']),
      scoreCount: _int(data['score_cnt']),
      scoreContext: _string(data['context']),
      hasMore: data['has_more'] == true,
      nextOffset: _int(data['next_offset']),
    );
  }
}

/// Unwraps `{code, data}` (and a nested `data.data`) down to the comment page.
Map<String, dynamic>? resolveCommentData(Map<String, dynamic> payload) {
  dynamic data = payload['data'] ?? payload;
  if (data is Map && data['data'] is Map) data = data['data'];
  if (data is! Map) return null;
  return Map<String, dynamic>.from(data);
}

/// Parses the `/novel/commentapi/comment/list/` response used by paragraph
/// comments (段评).
///
/// That service nests each entry as `data_list[i].comment` and reports page
/// counters under `common_list_info`, unlike the book-review endpoint's flat
/// `comment[]` plus `comment_cnt`. Both are normalized to [BookCommentPage].
BookCommentPage parseParagraphComments(Map<String, dynamic> payload) {
  // Any non-success business code means there is no usable page (103001
  // "invalid param", 1301008 "no available speech text", ...). Returning an
  // empty page keeps the caller on the "no comments" path instead of surfacing
  // a failure for a section that is only decoration.
  final code = payload['code'];
  if (code != null && code != 0 && code != 200) {
    return const BookCommentPage();
  }
  final raw = payload['data'];
  if (raw is! Map) return const BookCommentPage();
  final page = Map<String, dynamic>.from(raw);
  final info = page['common_list_info'];
  final infoMap = info is Map ? info : const {};

  final comments = <BookComment>[];
  final list = page['data_list'];
  if (list is List) {
    for (final entry in list) {
      if (entry is! Map) continue;
      final parsed = _paragraphComment(entry['comment'], entry['stat']);
      if (parsed != null) comments.add(parsed);
    }
  }
  return BookCommentPage(
    comments: List.unmodifiable(comments),
    totalCount: _int(infoMap['total']),
    hasMore: infoMap['has_more'] == true,
    nextOffset: _cursorOffset(_string(infoMap['cursor'])),
  );
}

/// Builds one comment from a `data_list[]` entry.
///
/// Note: the counters live inside `comment.stat` — see
/// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
///
/// The counters live **inside** `comment.stat`, not beside it; reading a sibling
/// `stat` silently reported zero likes for every paragraph comment.
BookComment? _paragraphComment(dynamic comment, dynamic stat) {
  if (comment is! Map) return null;
  final common = comment['common'];
  final commonMap = common is Map ? common : const {};
  final content = commonMap['content'];
  final contentMap = content is Map ? content : const {};
  final text = _string(contentMap['text']);
  if (text.isEmpty) return null;
  final user = commonMap['user_info'];
  final userMap = user is Map ? user : const {};
  final base = userMap['base_info'];
  final baseMap = base is Map ? base : const {};
  // Prefer the comment's own counters, and keep the sibling form working for
  // any payload that puts them there.
  final statMap = (comment['stat'] ?? stat) is Map
      ? (comment['stat'] ?? stat) as Map
      : const {};
  final tag = userMap['user_tag'];
  final tagMap = tag is Map ? tag : const {};
  return BookComment(
    id: _string(comment['comment_id']),
    text: text,
    diggCount: _int(statMap['digg_count']),
    replyCount: _int(statMap['reply_count']),
    readSeconds: _int(statMap['read_duration']),
    createdAt: _timestamp(commonMap['create_timestamp']),
    userName: _string(baseMap['user_name']),
    userAvatar: _string(baseMap['user_avatar']),
    isAuthor: tagMap['is_author'] == true,
  );
}

/// The upstream cursor is a JSON string such as `{"offset":20}`; keep the
/// offset so callers can page without parsing it themselves.
int _cursorOffset(String cursor) {
  final match = RegExp(r'"offset"\s*:\s*(\d+)').firstMatch(cursor);
  return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
}

/// Business error carried inside a 200 response. The timeline endpoint answers
/// with `code=1301008 / no available speech text` when a book has no subtitles,/// which callers treat as "feature unavailable" rather than a failure.
bool isUnavailableCode(dynamic code) {
  const unavailable = {1301008};
  final value = code is int ? code : int.tryParse('$code');
  return value != null && unavailable.contains(value);
}

/// `79528 -> 7.9万`; reused by the comment summary line.
String formatCount(int value) {
  if (value < 10000) return '$value';
  if (value < 100000000) {
    final text = (value / 10000).toStringAsFixed(1);
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}万';
  }
  final text = (value / 100000000).toStringAsFixed(1);
  return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}亿';
}

/// Upstream timestamps are seconds; tolerate milliseconds as well.
DateTime? _timestamp(dynamic value) {
  final raw = value is int ? value : int.tryParse('$value');
  if (raw == null || raw <= 0) return null;
  final milliseconds = raw > 100000000000 ? raw : raw * 1000;
  return DateTime.fromMillisecondsSinceEpoch(milliseconds);
}

String _string(dynamic value) => value == null ? '' : '$value'.trim();

int _int(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}
