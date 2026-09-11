/// Author profile and their works, from `/api/v1/authors/{id}`
/// (upstream `/reading/user/basic_info/get/v`).
///
/// Note: why the author's works come from `author_book_info` rather than
/// `/authors/{id}/bookshelf` — see
/// .agents/notes/implemented/feature/2026-09-11-discovery-pages.md
library;

import 'book_detail.dart' show formatCounter, formatWordCount;

/// One work in an author's catalogue.
class AuthorWork {
  const AuthorWork({
    this.id = '',
    this.title = '',
    this.cover = '',
    this.abstract = '',
    this.category = '',
    this.creationStatus = -1,
    this.wordNumber = 0,
    this.readCount = '',
  });

  final String id;
  final String title;
  final String cover;
  final String abstract;
  final String category;
  final int creationStatus;
  final int wordNumber;
  final String readCount;

  bool get isEmpty => id.isEmpty && title.isEmpty;

  bool get finished => creationStatus == 0;

  String get statusLabel => switch (creationStatus) {
    0 => '完结',
    1 => '连载中',
    4 => '停更',
    _ => '',
  };

  String get wordLabel => formatWordCount(wordNumber);

  /// Category · status · word count, the same shape the detail page shows.
  String get metaLabel => [
    if (category.isNotEmpty) category,
    if (statusLabel.isNotEmpty) statusLabel,
    if (wordLabel.isNotEmpty) wordLabel,
  ].join(' · ');

  static AuthorWork? fromRaw(dynamic raw) {
    if (raw is! Map) return null;
    final id = _string(raw['book_id']);
    final title = _string(raw['book_name']);
    if (id.isEmpty && title.isEmpty) return null;
    return AuthorWork(
      id: id,
      title: title,
      cover: _string(raw['thumb_url']),
      abstract: _string(raw['abstract']),
      category: _firstTag(raw['category']),
      creationStatus: _int(raw['creation_status'], fallback: -1),
      wordNumber: _int(raw['word_number']),
      readCount: _string(raw['read_count']),
    );
  }

  /// `category` is a comma separated list; the first entry is the primary one.
  static String _firstTag(dynamic raw) {
    final text = _string(raw);
    if (text.isEmpty) return '';
    return text.split(RegExp('[,，]')).first.trim();
  }
}

class AuthorProfile {
  const AuthorProfile({
    this.id = '',
    this.name = '',
    this.avatar = '',
    this.description = '',
    this.level = '',
    this.followerCount = 0,
    this.workCount = 0,
    this.works = const [],
  });

  static const empty = AuthorProfile();

  final String id;
  final String name;
  final String avatar;

  /// Author's own bio (`description`); `author_desc` is usually empty.
  final String description;

  /// Level badge text such as `作家Lv.5`.
  final String level;
  final int followerCount;

  /// Total works reported by the upstream, which can exceed [works].
  final int workCount;
  final List<AuthorWork> works;

  bool get isEmpty => id.isEmpty && name.isEmpty;

  /// `2.1万粉丝`, or empty when the count is unknown or zero — "0粉丝" is noise.
  String get followerLabel {
    if (followerCount <= 0) return '';
    final formatted = formatCounter('$followerCount');
    return formatted.isEmpty || formatted == '0' ? '' : '$formatted粉丝';
  }

  String get workCountLabel => workCount > 0 ? '$workCount 部作品' : '';

  /// Reads the profile payload. Accepts the `{code, data}` envelope; a business
  /// error yields [empty].
  static AuthorProfile fromPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code != null && code != 0 && code != 200) return empty;
    final data = payload['data'];
    if (data is! Map) return empty;
    final works = <AuthorWork>[];
    final raw = data['author_book_info'];
    if (raw is List) {
      for (final entry in raw) {
        final work = AuthorWork.fromRaw(entry);
        if (work != null) works.add(work);
      }
    }
    return AuthorProfile(
      id: _string(data['user_id']),
      name: _string(data['user_name']),
      avatar: _string(data['user_avatar']),
      // `description` carries the bio; `author_desc` is often blank.
      description: _string(
        data['description'],
      ).ifEmpty(_string(data['author_desc'])),
      level: _level(data['user_title_infos']),
      followerCount: _int(data['fans_num']),
      workCount: _int(data['author_book_num']),
      works: List.unmodifiable(works),
    );
  }

  /// The badge lives in `user_title_infos[].title_text`, e.g. `作家Lv.5`.
  static String _level(dynamic raw) {
    if (raw is! List) return '';
    for (final entry in raw) {
      if (entry is! Map) continue;
      final text = _string(entry['title_text']);
      if (text.isNotEmpty) return text;
    }
    return '';
  }
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
