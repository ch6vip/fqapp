/// 短剧评论 / 热评 / 弹幕的解析层。
///
/// 三类数据都出自同一个上游 `POST /novel/commentapi/comment/list/:group_id/v1/`：
/// 剧评的 group_id 是剧集 id（`gx1/m.java:168-181`），弹幕的 group_id 是 vid
/// （`DanmakuRequestHelper.java:303,318`）。响应形状与段评相同：
/// `data_list[i].comment.common.content.text` + `common_list_info`，
/// 因此复用 [BookComment] 的字段语义，额外保留短剧需要的 `dataType`。
///
/// 证据见 .agents/notes/proposed/architecture/2026-09-25-f04-official-evidence.md。
library;

import 'book_comment.dart';

/// 官方 `UgcRelativeType`（`J:UgcRelativeType.java:9-55`）。
class UgcRelativeType {
  const UgcRelativeType._();

  static const book = 1;
  static const comment = 4;
  static const reply = 9;
  static const seriesVideo = 30;
}

/// 官方 `UgcSortEnum`（`J:UgcSortEnum.java:6-9`）。
class UgcSort {
  const UgcSort._();

  /// 「全部」用的排序。
  static const smartHot = 1;
  static const timeAsc = 2;

  /// 「最新」用的排序。
  static const timeDesc = 3;
}

/// 一条短剧评论（或弹幕，形状相同）。
class PlayletComment {
  const PlayletComment({
    this.id = '',
    this.text = '',
    this.diggCount = 0,
    this.replyCount = 0,
    this.createdAt,
    this.userName = '',
    this.userAvatar = '',
    this.dataType = UgcRelativeType.comment,
    this.parentCommentId = '',
    this.playletRoleType = 0,
    this.offsetMs = 0,
  });

  final String id;
  final String text;
  final int diggCount;
  final int replyCount;
  final DateTime? createdAt;
  final String userName;
  final String userAvatar;

  /// 官方 `mixData.dataType`：4=Comment、9=Reply。热评筛选与点击联动都依赖它。
  final int dataType;

  /// 回复型热评要带上父评论 id（`a13/w.java:383-424`）。
  final String parentCommentId;

  /// `comment.expand.playletRoleType`（「演员说：」等前缀的判据）。
  final int playletRoleType;

  /// 弹幕在视频里的时间点（毫秒）。剧评恒为 0。
  final int offsetMs;

  bool get isEmpty => text.trim().isEmpty;

  /// 官方热评前缀：0x7f061960/61/62 =「演员说：/主演说：/热评：」。
  String get rolePrefix => switch (playletRoleType) {
    1 => '演员说：',
    2 => '主演说：',
    _ => '热评：',
  };

  String relativeTime({DateTime? now}) => BookComment(
    id: id,
    text: text,
    createdAt: createdAt,
  ).relativeTime(now: now);

  static PlayletComment? fromRaw(dynamic entry) {
    if (entry is! Map) return null;
    final comment = entry['comment'];
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
    final stat = comment['stat'];
    final statMap = stat is Map ? stat : const {};
    final expand = comment['expand'];
    final expandMap = expand is Map ? expand : const {};
    final mix = entry['mix_data'] ?? entry['mixData'];
    final mixMap = mix is Map ? mix : const {};
    final parent = mixMap['parent'];
    final parentMap = parent is Map ? parent : const {};
    final parentComment = parentMap['comment'];
    final parentCommentMap = parentComment is Map ? parentComment : const {};

    return PlayletComment(
      id: _string(comment['comment_id']),
      text: text,
      diggCount: _int(statMap['digg_count']),
      replyCount: _int(statMap['reply_count']),
      createdAt: _timestamp(commonMap['create_timestamp']),
      userName: _string(baseMap['user_name']),
      userAvatar: _string(baseMap['user_avatar']),
      // dataType 可能来自 mix_data，也可能直接挂在条目上；两者都容忍。
      dataType: _int(mixMap['data_type'] ?? entry['data_type']).ifZero(
        UgcRelativeType.comment,
      ),
      parentCommentId: _string(parentCommentMap['comment_id']),
      playletRoleType: _int(expandMap['playlet_role_type']),
    );
  }

  /// 弹幕条目：同一条响应，时间点来自 `comment.expand` 或 `business_param`。
  static PlayletComment? fromDanmakuRaw(dynamic entry) {
    final base = fromRaw(entry);
    if (base == null) return null;
    final comment = (entry as Map)['comment'];
    final commentMap = comment is Map ? comment : const {};
    final expand = commentMap['expand'];
    final expandMap = expand is Map ? expand : const {};
    return PlayletComment(
      id: base.id,
      text: base.text,
      diggCount: base.diggCount,
      replyCount: base.replyCount,
      createdAt: base.createdAt,
      userName: base.userName,
      userAvatar: base.userAvatar,
      dataType: base.dataType,
      parentCommentId: base.parentCommentId,
      playletRoleType: base.playletRoleType,
      offsetMs: _int(expandMap['offset']),
    );
  }
}

/// 一页短剧评论 / 弹幕。
class PlayletCommentPage {
  const PlayletCommentPage({
    this.comments = const [],
    this.totalCount = 0,
    this.hasMore = false,
    this.cursor = '',
    this.hotComments = const [],
  });

  final List<PlayletComment> comments;
  final int totalCount;
  final bool hasMore;
  final String cursor;

  /// 官方热评 = 同一份列表里筛出的 [UgcRelativeType.comment]/[reply]
  /// （`a13/w.java:351-426`），不是接口字段。
  final List<PlayletComment> hotComments;

  bool get isEmpty => comments.isEmpty;

  /// 官方空态：计数 >0 用「无相关剧评」，==0 用「期待你的第一条剧评」
  /// （`gx1/n0.java:698-708`）。
  String get emptyText =>
      totalCount > 0 ? '无相关剧评' : '期待你的第一条剧评';

  /// 官方入口计数：0 时「抢首评」/「评论」（`SeriesCommentView.java:182-188`）。
  static String entryLabel(int count) {
    if (count <= 0) return '评论';
    return formatCount(count);
  }

  static PlayletCommentPage fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) {
      return const PlayletCommentPage();
    }
    final raw = payload['data'];
    if (raw is! Map) return const PlayletCommentPage();
    final page = Map<String, dynamic>.from(raw);
    final info = page['common_list_info'];
    final infoMap = info is Map ? info : const {};

    final comments = <PlayletComment>[];
    final list = page['data_list'];
    if (list is List) {
      for (final entry in list) {
        final parsed = PlayletComment.fromRaw(entry);
        if (parsed != null) comments.add(parsed);
      }
    }
    return PlayletCommentPage(
      comments: List.unmodifiable(comments),
      totalCount: _int(infoMap['total']),
      hasMore: infoMap['has_more'] == true,
      cursor: _string(infoMap['cursor']),
      hotComments: List.unmodifiable(hotOf(comments)),
    );
  }

  /// 弹幕取数用同一个响应形状，只是时间点也要读出来。
  static PlayletCommentPage fromDanmakuPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) {
      return const PlayletCommentPage();
    }
    final raw = payload['data'];
    if (raw is! Map) return const PlayletCommentPage();
    final page = Map<String, dynamic>.from(raw);
    final info = page['common_list_info'];
    final infoMap = info is Map ? info : const {};
    final comments = <PlayletComment>[];
    final list = page['data_list'];
    if (list is List) {
      for (final entry in list) {
        final parsed = PlayletComment.fromDanmakuRaw(entry);
        if (parsed != null) comments.add(parsed);
      }
    }
    return PlayletCommentPage(
      comments: List.unmodifiable(comments),
      totalCount: _int(infoMap['total']),
      hasMore: infoMap['has_more'] == true,
      cursor: _string(infoMap['cursor']),
    );
  }
}

/// 官方热评筛选：`dataType in {Comment, Reply}`（`a13/w.java:351-426`）。
List<PlayletComment> hotOf(List<PlayletComment> comments) => [
  for (final comment in comments)
    if (comment.dataType == UgcRelativeType.comment ||
        comment.dataType == UgcRelativeType.reply)
      comment,
];

/// 官方分享面板里「复制链接」的固定文案（`LinkShareItem.java:68-72`，
/// 字符串资源 0x7f061a1c）。
const shareCopyLinkLabel = '复制链接';

/// 复制成功的 Toast 在官方是**硬编码**串（`LinkShareItem.java:117-122`）。
const shareCopiedToast = '链接已复制，快去分享吧';

/// 官方没有可得分享数据时的兜底文案（`m0.java:2118`，0x7f060463）。
const shareUnavailableToast = '网络错误，请重试';

/// 弹幕开关的官方 Toast（0x7f060bb1 / 0x7f060bb2）。
const danmakuEnabledToast = '弹幕已开启';
const danmakuDisabledToast = '弹幕已关闭，长按视频可开启';

/// 官方弹幕输入框占位（`VideoDanmakuSettingConfig` 默认提示语）。
const danmakuHint = '发条友善的弹幕吧';

String _string(dynamic value) => value == null ? '' : '$value'.trim();

int _int(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.isFinite ? value.toInt() : 0;
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

DateTime? _timestamp(dynamic value) {
  final raw = value is int ? value : int.tryParse('$value');
  if (raw == null || raw <= 0) return null;
  final milliseconds = raw > 100000000000 ? raw : raw * 1000;
  if (milliseconds > 8640000000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(milliseconds);
}

extension on int {
  int ifZero(int fallback) => this == 0 ? fallback : this;
}
