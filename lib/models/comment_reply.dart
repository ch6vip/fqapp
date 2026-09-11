/// Replies to a book review, from `/api/v1/comments/{id}/replies`.
///
/// The endpoint requires all three of `comment_id`, `group_id` and `book_id`;
/// omitting any of them answers 400. Each entry nests its body under `Common`
/// (capital C), like the paragraph-comment service.
///
/// Note: why replies need a separate call — see
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
library;

class CommentReply {
  const CommentReply({
    this.id = '',
    this.text = '',
    this.userName = '',
    this.userAvatar = '',
    this.diggCount = 0,
    this.createdAt,
  });

  final String id;
  final String text;
  final String userName;
  final String userAvatar;
  final int diggCount;
  final DateTime? createdAt;

  bool get isEmpty => text.trim().isEmpty;

  /// Relative publish time, matching the review list.
  String relativeTime({DateTime? now}) {
    final created = createdAt;
    if (created == null) return '';
    final seconds = (now ?? DateTime.now()).difference(created).inSeconds;
    if (seconds < 60) return '刚刚';
    if (seconds < 3600) return '${seconds ~/ 60}分钟前';
    if (seconds < 86400) return '${seconds ~/ 3600}小时前';
    if (seconds < 86400 * 30) return '${seconds ~/ 86400}天前';
    if (seconds < 86400 * 365) return '${seconds ~/ (86400 * 30)}个月前';
    return '${seconds ~/ (86400 * 365)}年前';
  }

  static CommentReply? fromRaw(dynamic raw) {
    if (raw is! Map) return null;
    final common = raw['Common'] ?? raw['common'];
    if (common is! Map) return null;
    final content = common['content'];
    final text = content is Map ? _string(content['text']) : '';
    if (text.isEmpty) return null;
    final user = common['user_info'];
    final base = user is Map ? user['base_info'] : null;
    final baseMap = base is Map ? base : const {};
    final stat = raw['stat'];
    final statMap = stat is Map ? stat : const {};
    return CommentReply(
      id: _string(raw['reply_id']),
      text: text,
      userName: _string(baseMap['user_name']),
      userAvatar: _string(baseMap['user_avatar']),
      diggCount: _int(statMap['digg_count']),
      createdAt: _timestamp(common['create_timestamp']),
    );
  }
}

/// A page of replies plus whether more remain.
class CommentReplyPage {
  const CommentReplyPage({
    this.replies = const [],
    this.totalCount = 0,
    this.hasMore = false,
  });

  static const empty = CommentReplyPage();

  final List<CommentReply> replies;
  final int totalCount;
  final bool hasMore;

  bool get isEmpty => replies.isEmpty;
  bool get isNotEmpty => replies.isNotEmpty;

  String get headerLabel => totalCount > 0 ? '共 $totalCount 条回复' : '回复';

  static CommentReplyPage fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return empty;
    final data = payload['data'];
    if (data is! Map) return empty;
    final replies = <CommentReply>[];
    final raw = data['reply_list'];
    if (raw is List) {
      for (final entry in raw) {
        final reply = CommentReply.fromRaw(entry);
        if (reply != null) replies.add(reply);
      }
    }
    final info = data['comment_list_info'];
    final infoMap = info is Map ? info : const {};
    return CommentReplyPage(
      replies: List.unmodifiable(replies),
      totalCount: _int(infoMap['total']),
      hasMore: infoMap['has_more'] == true,
    );
  }
}

String _string(dynamic value) => value == null ? '' : '$value'.trim();

int _int(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

/// Seconds upstream; milliseconds tolerated.
DateTime? _timestamp(dynamic value) {
  final raw = value is int ? value : int.tryParse('$value');
  if (raw == null || raw <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    raw > 100000000000 ? raw : raw * 1000,
  );
}
