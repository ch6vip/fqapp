/// Short-drama series detail, including the cast list the detail page shows.
///
/// Comes from `/api/v1/series/{id}` (upstream `POST /novel/player/video_detail/v1/`).
/// The reading-API endpoints the page already used carry no cast data, so the
/// actor row can only be filled from here.
///
/// Note: why the cast needs its own endpoint, and how the avatar format was
/// verified — see
/// .agents/notes/implemented/feature/2026-09-11-short-drama-cast.md
library;

import 'book_detail.dart' show formatCounter;

/// One cast member: an actor and the role they play.
class CastMember {
  const CastMember({
    this.id = '',
    this.actor = '',
    this.role = '',
    this.avatar = '',
    this.intro = '',
  });

  final String id;

  /// The performer's name (`nickname` upstream).
  final String actor;

  /// Character played (`role_name` upstream).
  final String role;

  /// Avatar URL. Upstream serves these as HEIC; callers must tolerate a decode
  /// failure and fall back to an initial.
  final String avatar;
  final String intro;

  bool get isEmpty => actor.isEmpty && role.isEmpty;

  /// One character to show when the avatar is missing or cannot be decoded.
  String get initial {
    final source = actor.trim();
    if (source.isEmpty) return '?';
    return String.fromCharCode(source.runes.first);
  }

  /// `张楸梓 饰 林汐`, or just the name when no role is known.
  String get label => role.isEmpty ? actor : '$actor 饰 $role';

  static CastMember? fromRaw(dynamic raw) {
    if (raw is! Map) return null;
    final actor = _string(raw['nickname']);
    final role = _string(raw['role_name']);
    if (actor.isEmpty && role.isEmpty) return null;
    return CastMember(
      id: _string(raw['celebrity_id']),
      actor: actor,
      role: role,
      avatar: _string(raw['avatar']),
      intro: _string(raw['intro']),
    );
  }
}

/// Series-level detail for a short drama.
class SeriesDetail {
  const SeriesDetail({
    this.seriesId = '',
    this.title = '',
    this.intro = '',
    this.cover = '',
    this.cast = const [],
    this.episodeCount = 0,
    this.episodeLabel = '',
    this.playCount = 0,
    this.followerCount = 0,
    this.categories = const [],
    this.originalBook,
    this.status,
  });

  static const empty = SeriesDetail();

  final String seriesId;
  final String title;
  final String intro;
  final String cover;
  final List<CastMember> cast;

  /// Episode total. `episode_cnt` upstream; falls back to the directory count.
  final int episodeCount;

  /// Ready-made label such as `全66集`.
  final String episodeLabel;
  final int playCount;
  final int followerCount;
  final List<String> categories;

  /// 原著书卡（官方播放页底部 `BottomRelateBookView`，数据在
  /// `video_relate_book.book_info`）。剧无原著关联时为 null。
  final SeriesRelateBook? originalBook;

  /// `series_status`（官方 `SeriesStatus` 枚举：**1=已完结**、0=更新中、
  /// 3=今日更新、4=断更——注意与书库 creation_status 的 0=完结/1=连载
  /// 语义相反）。null = 未知。
  final int? status;

  bool get isEmpty => title.isEmpty && cast.isEmpty;

  /// Play counter formatted the way the app shows other large numbers.
  String get playLabel => formatCounter('$playCount');

  /// Parses the series detail payload. `{code, data}` with the record under
  /// `data.video_data`; a business error yields [empty].
  static SeriesDetail fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return empty;
    final data = payload['data'];
    if (data is! Map) return empty;
    final video = data['video_data'];
    if (video is! Map) return empty;

    return SeriesDetail(
      seriesId: _string(
        video['series_id_str'],
      ).ifEmpty(_string(video['series_id'])),
      title: _string(video['series_title']),
      intro: _string(video['series_intro']),
      cover: _string(video['series_cover']),
      cast: _castList(video['celebrities']),
      episodeCount: _int(video['episode_cnt']),
      episodeLabel: _string(video['episode_right_text']),
      playCount: _int(video['series_play_cnt']),
      followerCount: _int(video['followed_cnt']),
      categories: _categoryNames(video['category_schema']),
      originalBook: _relateBook(data['video_relate_book']),
      status: video['series_status'] == null
          ? null
          : _int(video['series_status']),
    );
  }
}

/// `video_relate_book.book_info`（官方 `SaasBookInfo`：book_id/book_name/
/// creation_status/thumb_url…）。
class SeriesRelateBook {
  const SeriesRelateBook({
    this.id = '',
    this.title = '',
    this.cover = '',
    this.status = '',
  });

  final String id;
  final String title;
  final String cover;
  final String status;
}

SeriesRelateBook? _relateBook(dynamic raw) {
  if (raw is! Map) return null;
  final info = raw['book_info'];
  if (info is! Map) return null;
  final id = _string(info['book_id']);
  final title = _string(info['book_name']);
  if (id.isEmpty || title.isEmpty) return null;
  return SeriesRelateBook(
    id: id,
    title: title,
    cover: _string(info['thumb_url']),
    status: _string(info['creation_status']),
  );
}

List<CastMember> _castList(dynamic raw) {
  if (raw is! List) return const [];
  final cast = <CastMember>[];
  for (final entry in raw) {
    final member = CastMember.fromRaw(entry);
    if (member != null) cast.add(member);
  }
  return List.unmodifiable(cast);
}

/// `category_schema` is a JSON string holding a list of category objects.
List<String> _categoryNames(dynamic raw) {
  final text = _string(raw);
  if (text.isEmpty) return const [];
  final names = <String>[];
  // The field arrives as an embedded JSON document in the tests and from the
  // live API, but tolerate a plain comma separated string as well.
  final matches = RegExp(r'"name"\s*:\s*"([^"]+)"').allMatches(text);
  for (final match in matches) {
    final name = match.group(1)?.trim() ?? '';
    if (name.isNotEmpty) names.add(name);
  }
  if (names.isEmpty) {
    for (final part in text.split(RegExp('[,，]'))) {
      final name = part.trim();
      if (name.isNotEmpty) names.add(name);
    }
  }
  return List.unmodifiable(names);
}

String _string(dynamic value) => value == null ? '' : '$value'.trim();

int _int(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
