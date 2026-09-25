/// Normalized content models used by the Flutter client.
///
/// The upstream service returns different field names for novels, short
/// dramas, comics and audio books.  Keep that compatibility code here so the
/// pages only deal with stable, typed values.
library;

import 'dart:isolate';

bool isVideoKind(String kind) => kind == 'video' || kind == 'manju';

/// Runs [parseMediaItems] on a background isolate so deep recursive payload
/// traversal never janks the UI thread.
Future<List<MediaItem>> parseMediaItemsAsync(Map<String, dynamic> payload) =>
    Isolate.run(() => parseMediaItems(payload));

/// Runs [parseSearchTabs] on a background isolate.
Future<List<SearchTab>> parseSearchTabsAsync(Map<String, dynamic> payload) =>
    Isolate.run(() => parseSearchTabs(payload));

/// Runs [parseDirectory] on a background isolate (large chapter lists).
Future<List<List<Chapter>>> parseDirectoryAsync(Map<String, dynamic> payload) =>
    Isolate.run(() => parseDirectory(payload));

class MediaItem {
  static final _videoRe = RegExp(r'短剧|短片|剧集|video|drama', caseSensitive: false);
  static final _mangaRe = RegExp(r'漫画|轻漫|条漫|comic|manga', caseSensitive: false);
  static final _audioRe = RegExp(
    r'有声|听书|音频|朗读|audio|novelfm',
    caseSensitive: false,
  );

  final String id;
  final String title;
  final String cover;
  final String author;
  final String badge;
  final String ep;
  final String kind; // 'book' | 'video' | 'manju' | 'manga' | 'audio'

  /// Decorative corner tag the upstream attaches to some cards, e.g. `上新` or
  /// `爆款`. Null when the card carries none.
  final MediaTag? tag;

  /// For short dramas, seriesId is the ID accepted by the pseries directory
  /// endpoint and episodeId is an optional individual video ID.
  final String? seriesId;
  final String? episodeId;

  /// Series synopsis (`series_intro` in the 短剧 template cell's
  /// `video_detail`). Empty when the card carries none.
  final String intro;

  /// 追剧人数 (`followed_cnt` in `video_detail`), 0 when absent. This is the
  /// count the official right rail shows under the star button.
  final int followerCount;

  /// Category names for the info panel's chip row: `secondary_infos` entries
  /// with `data_type == 3` (categories), falling back to `category_schema`
  /// names. Empty when the card carries neither.
  final List<String> categories;

  /// 「作者声明：内容由AI生成」行（`video_detail.ai_usage_type > 0`，
  /// 官方播放页信息层按它渲染声明行）。
  final bool aiGenerated;

  /// Server-authored pill copy (`style.episode_list_text`, e.g.
  /// 「观看完整漫剧·全153集」). The feed card's pill builds its own
  /// 「观看全集·N集」 from the episode count, so this is informational.
  final String episodeListText;

  MediaItem({
    required this.id,
    required this.title,
    required this.cover,
    required this.author,
    required this.badge,
    required this.ep,
    required this.kind,
    this.tag,
    this.seriesId,
    this.episodeId,
    this.intro = '',
    this.followerCount = 0,
    this.categories = const [],
    this.episodeListText = '',
    this.aiGenerated = false,
  });

  /// Copy with selected fields replaced.
  ///
  /// Callers that need to rebuild an item with one field changed (the home feed
  /// forcing a category's kind, for instance) must use this instead of calling
  /// the constructor by hand: a hand-written rebuild silently drops any field
  /// added later, which is exactly how the cover badge went missing on the home
  /// feed. Nullable fields cannot be cleared through this method, which is fine
  /// for its callers and keeps the signature free of sentinels.
  MediaItem copyWith({
    String? id,
    String? title,
    String? cover,
    String? author,
    String? badge,
    String? ep,
    String? kind,
    MediaTag? tag,
    String? seriesId,
    String? episodeId,
    String? intro,
    int? followerCount,
    List<String>? categories,
    String? episodeListText,
    bool? aiGenerated,
  }) => MediaItem(
    id: id ?? this.id,
    title: title ?? this.title,
    cover: cover ?? this.cover,
    author: author ?? this.author,
    badge: badge ?? this.badge,
    ep: ep ?? this.ep,
    kind: kind ?? this.kind,
    tag: tag ?? this.tag,
    seriesId: seriesId ?? this.seriesId,
    episodeId: episodeId ?? this.episodeId,
    intro: intro ?? this.intro,
    followerCount: followerCount ?? this.followerCount,
    categories: categories ?? this.categories,
    episodeListText: episodeListText ?? this.episodeListText,
    aiGenerated: aiGenerated ?? this.aiGenerated,
  );

  factory MediaItem.fromRaw(Map<String, dynamic> item) {
    final bd = _mapFrom(item['book_data']) ?? item;
    final titleObj = item['title'];
    final highlightTitle =
        _dig(item, ['search_high_light', 'title', 'text']) ??
        _dig(titleObj, ['text']);

    final explicitKind = _normalizeKind(item['kind']);
    final kind = explicitKind.isNotEmpty
        ? explicitKind
        : _isManjuItem(item, bd)
        ? 'manju'
        : _isVideoItem(item, bd)
        ? 'video'
        : _isMangaItem(item, bd)
        ? 'manga'
        : _isAudioItem(item, bd)
        ? 'audio'
        : 'book';

    // `series_id_str` first: the numeric `series_id` of the 短剧 template cells is
    // shipped as a JSON double and is already truncated upstream
    // (`…880000` vs the exact `…880409`), so the string form is the only usable
    // identifier for the series detail / episode lookups.
    final seriesKeys = <String>['series_id_str', 'pseries_id', 'series_id'];
    // A search cell can wrap episodes in video_data and expose the series
    // identifier only as its book_id. A standalone video result should keep
    // its video_id instead, because that is what /api/content accepts.
    if (item['video_data'] is List) seriesKeys.add('book_id');
    final seriesId = isVideoKind(kind)
        ? (_firstString(item, ['seriesId']) ??
              _firstString(item, seriesKeys) ??
              _firstString(bd, seriesKeys))
        : null;
    final episodeId = isVideoKind(kind)
        ? (_firstString(item, [
                'episodeId',
                'video_id',
                'vid',
                'item_id',
                'id',
              ]) ??
              _firstString(bd, ['video_id', 'vid', 'item_id', 'id']))
        : null;

    final idKeys = switch (kind) {
      'video' || 'manju' => [
        'series_id_str',
        'video_id',
        'vid',
        'pseries_id',
        'series_id',
        'item_id',
        'id',
        'book_id',
        'cell_id',
      ],
      'manga' => [
        'manga_id',
        'comic_id',
        'book_id',
        'item_id',
        'id',
        'cell_id',
      ],
      'audio' => [
        'audio_book_id',
        'audio_id',
        'album_id',
        'book_id',
        'item_id',
        'id',
        'cell_id',
      ],
      _ => ['book_id', 'item_id', 'id', 'cell_id'],
    };

    // Corner tag. It rides on the card object itself, alongside title/cover,
    // and carries its own label and both light/dark gradients.
    final tagInfo = _mapFrom(item['tag_info']) ?? _mapFrom(bd['tag_info']);

    // 短剧模板卡的信息面板数据：简介/追剧数在 video_detail（visit() 已摊平到
    // item 上），分类 chip 在 secondary_infos（data_type=3），其 fallback 是
    // category_schema 里的 name 列表。style 骑在模板 cell 本体上。
    final followedCount =
        _asInt(item['followed_cnt']) ?? _asInt(bd['followed_cnt']) ?? 0;
    final aiUsageType =
        _asInt(item['ai_usage_type']) ?? _asInt(bd['ai_usage_type']) ?? 0;
    final styleInfo = _mapFrom(item['style']) ?? _mapFrom(bd['style']);
    final episodeListText =
        _firstString(styleInfo ?? const {}, ['episode_list_text']) ?? '';
    final categories = _secondaryCategories(
      item['secondary_infos'] ?? bd['secondary_infos'],
      fallback: item['category_schema'] ?? bd['category_schema'],
    );

    return MediaItem(
      id:
          seriesId ??
          _firstString(bd, idKeys) ??
          _firstString(item, idKeys) ??
          '',
      kind: kind,
      seriesId: seriesId,
      episodeId: episodeId,
      tag: MediaTag.fromRaw(tagInfo),
      title:
          highlightTitle ??
          _firstString(item, ['series_title', 'title', 'name', 'raw_book_name']) ??
          _firstString(bd, ['title', 'name', 'raw_book_name', 'book_name']) ??
          _firstString(item, ['book_name']) ??
          _firstString(item, ['cell_name']) ??
          '未知',
      cover:
          _firstString(item, [
            'series_cover',
            'thumb_url',
            'cover',
            'cover_url',
            'poster',
          ]) ??
          _firstString(bd, ['thumb_url', 'cover', 'cover_url', 'poster']) ??
          '',
      author:
          _firstString(item, ['author', 'author_name']) ??
          _firstString(bd, ['author', 'author_name']) ??
          '',
      badge:
          _firstString(item, [
            'badge',
            'category',
            'type',
            'cell_alias',
            'card_tips',
            'book_type_name',
          ]) ??
          _firstString(bd, [
            'badge',
            'category',
            'type',
            'cell_alias',
            'card_tips',
            'book_type_name',
          ]) ??
          '',
      ep:
          _firstString(item, [
            'ep',
            'serial_count',
            'item_count',
            'episode_count',
            'episode_cnt',
          ]) ??
          _firstString(bd, [
            'ep',
            'serial_count',
            'item_count',
            'episode_count',
            'episode_cnt',
          ]) ??
          '',
      intro:
          _firstString(item, ['series_intro', 'intro']) ??
          _firstString(bd, ['series_intro', 'intro']) ??
          '',
      followerCount: followedCount,
      categories: categories,
      episodeListText: episodeListText,
      aiGenerated: aiUsageType > 0,
    );
  }

  static bool _isVideoItem(Map<String, dynamic> item, Map<String, dynamic> bd) {
    final text = _textBlob([
      item['category'],
      item['type'],
      item['book_type_name'],
      item['cell_alias'],
      item['card_tips'],
      bd['category'],
      bd['type'],
      bd['book_type_name'],
    ]);
    // Work detail records identify short dramas as genre=203 even without
    // the video fields that search cards carry.
    return _matchesGenre(item, 203) ||
        _matchesGenre(bd, 203) ||
        _truthyAny(item, [
          'video_id',
          'vid',
          'pseries_id',
          'series_id',
          'video_platform',
          'use_video_model',
        ]) ||
        _truthyAny(bd, [
          'video_id',
          'vid',
          'pseries_id',
          'series_id',
          'video_platform',
          'use_video_model',
        ]) ||
        _videoRe.hasMatch(text);
  }

  // Note: 漫剧的类型证据与视频接口复用，见
  // .agents/notes/implemented/feature/2026-09-09-manju.md
  static bool _isManjuItem(Map<String, dynamic> item, Map<String, dynamic> bd) {
    bool hasTag(dynamic value) {
      if (value is Map) return hasTag(value['text']);
      if (value is Iterable) return value.any(hasTag);
      return value is String &&
          const {'漫剧', '动态漫', '动态漫画'}.contains(value.trim());
    }

    bool matches(Map<String, dynamic> value) =>
        _matchesGenre(value, 205) ||
        hasTag(value['tag_info']) ||
        hasTag(value['cover_tag_info_list']) ||
        hasTag(value['book_type_name']) ||
        hasTag(value['type']);
    // Titles, synopses and publisher names may mention adaptations. Only
    // structured genre/tag metadata identifies the video itself as a manju.
    return matches(item) || matches(bd);
  }

  static String _normalizeKind(dynamic value) {
    final raw = value?.toString().trim().toLowerCase() ?? '';
    switch (raw) {
      case 'manju':
      case 'comic_drama':
      case '漫剧':
      case '动态漫':
        return 'manju';
      case 'video':
      case 'drama':
      case 'short_drama':
      case 'short-drama':
      case '短剧':
      case '短片':
        return 'video';
      case 'manga':
      case 'comic':
      case '漫画':
        return 'manga';
      case 'audio':
      case 'audiobook':
      case 'audio_book':
      case '听书':
      case '有声':
        return 'audio';
      case 'book':
      case 'novel':
      case '小说':
        return 'book';
      default:
        return '';
    }
  }

  static bool _isMangaItem(Map<String, dynamic> item, Map<String, dynamic> bd) {
    final text = _textBlob([
      item['category'],
      item['type'],
      item['book_type_name'],
      item['cell_alias'],
      item['card_tips'],
      bd['category'],
      bd['type'],
      bd['book_type_name'],
    ]);
    // The dedicated manga search (tab_type=8) uses this numeric genre pair.
    // Genre 6 also contains ordinary publications, so it cannot identify a
    // comic even when a copied search tab is labelled "漫画".
    return _matchesGenre(item, 1, 110) ||
        _matchesGenre(bd, 1, 110) ||
        _truthyAny(item, [
          'manga_id',
          'comic_id',
          'manga_type',
          'manga_info',
          'comic_info',
          'is_manga',
          'is_comic',
        ]) ||
        _truthyAny(bd, [
          'manga_id',
          'comic_id',
          'manga_info',
          'comic_info',
          'is_manga',
          'is_comic',
        ]) ||
        _mangaRe.hasMatch(text);
  }

  static bool _isAudioItem(Map<String, dynamic> item, Map<String, dynamic> bd) {
    final text = _textBlob([
      item['category'],
      item['type'],
      item['book_type_name'],
      item['cell_alias'],
      item['card_tips'],
      bd['category'],
      bd['type'],
      bd['book_type_name'],
    ]);
    // Actual audio-book search cards can have only book_id and genre=4;
    // their title and category need not mention audio or listening.
    return _matchesGenre(item, 4) ||
        _matchesGenre(bd, 4) ||
        _truthyAny(item, [
          'album_id',
          'audio_book_id',
          'audio_id',
          'listen_book_id',
          'audio_info',
          'tone_id',
          'is_audio',
          'is_listen',
        ]) ||
        _truthyAny(bd, [
          'album_id',
          'audio_book_id',
          'audio_id',
          'audio_info',
          'tone_id',
          'is_audio',
          'is_listen',
        ]) ||
        _audioRe.hasMatch(text);
  }

  static bool _matchesGenre(
    Map<String, dynamic> item,
    int genre, [
    int? genreType,
  ]) {
    bool matches(dynamic value, int expected) =>
        value == expected ||
        (value is String && value.trim() == expected.toString());
    return matches(item['genre'], genre) &&
        (genreType == null || matches(item['genre_type'], genreType));
  }

  static bool _truthyAny(Map<String, dynamic> map, List<String> keys) {
    return keys.any((key) => _truthy(map[key]));
  }

  static bool _truthy(dynamic value) {
    if (value == null || value == '' || value == 0 || value == false) {
      return false;
    }
    return true;
  }

  static Map<String, dynamic>? _mapFrom(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is List && value.isNotEmpty && value.first is Map) {
      return Map<String, dynamic>.from(value.first as Map);
    }
    return null;
  }

  static String _textBlob(Iterable<dynamic> values) {
    final out = <String>[];
    void visit(dynamic value) {
      if (value == null) return;
      if (value is Iterable) {
        for (final v in value) {
          visit(v);
        }
      } else if (value is Map) {
        for (final key in [
          'name',
          'title',
          'text',
          'category',
          'type',
          'tag_name',
          'tag_title',
        ]) {
          visit(value[key]);
        }
      } else {
        out.add(value.toString());
      }
    }

    for (final value in values) {
      visit(value);
    }
    return out.join(' ');
  }

  static String? _dig(dynamic value, List<String> keys) {
    dynamic current = value;
    for (final key in keys) {
      if (current is Map) {
        current = current[key];
      } else {
        return null;
      }
    }
    return current is String && current.isNotEmpty ? current : null;
  }

  static String? _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num && value != 0) return value.toString();
    }
    return null;
  }
}

/// A decorative corner chip the upstream attaches to a card (e.g. `上新`).
///
/// The label and its gradient both come from the payload: `上新` is green while
/// `爆款` is red, so neither can be hardcoded. Colours are kept as hex strings
/// to keep this model free of Flutter types.
class MediaTag {
  final String text;
  final List<String> lightColors;
  final List<String> darkColors;

  const MediaTag({
    required this.text,
    this.lightColors = const [],
    this.darkColors = const [],
  });

  /// Colours to use for [dark], falling back to the other set and then to none
  /// so a payload that only ships one variant still renders.
  List<String> colorsFor({required bool dark}) {
    if (dark) {
      return darkColors.isNotEmpty ? darkColors : lightColors;
    }
    return lightColors.isNotEmpty ? lightColors : darkColors;
  }

  /// Whether the upstream supplied a gradient.
  ///
  /// This is what separates a promotional badge from a plain label: on the
  /// home feed `tag_info` is only ever `上新`/`爆款` (both coloured), while in
  /// search results the same field also carries the kind label (`漫剧`,
  /// `小说改编`) with no colours. Cards already show the kind, so only coloured
  /// tags are rendered as a badge.
  bool get hasColors => lightColors.isNotEmpty || darkColors.isNotEmpty;

  static MediaTag? fromRaw(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    final text = raw['text'];
    final label = text is String ? text.trim() : '';
    if (label.isEmpty) return null;
    return MediaTag(
      text: label,
      lightColors: _hexList(raw['bg_color']),
      darkColors: _hexList(raw['dark_bg_color']),
    );
  }

  /// Keeps only well-formed `#RRGGBB` values, so a malformed payload cannot
  /// produce an unparseable colour later.
  static List<String> _hexList(dynamic value) {
    if (value is! List) return const [];
    final out = <String>[];
    for (final entry in value) {
      if (entry is! String) continue;
      final hex = entry.trim();
      if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) out.add(hex);
    }
    return List.unmodifiable(out);
  }
}

/// A text chapter or short-drama episode in a directory.
class Chapter {
  final String itemId;
  final String title;
  final String volumeName;

  /// Chapter content version from the directory (`item_data_list[i].version`).
  ///
  /// Paragraph comments cannot be listed without it: the upstream answers
  /// `103001 book_id, item_version, or para_index invalid` when it is missing.
  /// Empty for chapters restored from a cache written before it was kept.
  ///
  /// Note: why a novel directory must be read with [Chapter.fromRaw] — see
  /// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
  final String version;

  /// 官方选集格子的元数据（`hj3/r0.java:413-419,539-554` 的
  /// `SaasVideoData` 字段）。JSON 侧的键名**未取证**（Gson 按字段名原样
  /// 读写，上游可能换成下划线风格），因此解析时多种拼写都接受，
  /// 读不到就当 false——这是「宁可不显示角标」而不是「宁可不显示入口」。
  final bool trailer;
  final bool highlight;
  final bool disabled;
  final bool newlyUpdate;

  Chapter({
    required this.itemId,
    required this.title,
    required this.volumeName,
    this.version = '',
    this.trailer = false,
    this.highlight = false,
    this.disabled = false,
    this.newlyUpdate = false,
  });

  factory Chapter.fromRaw(Map<String, dynamic> m, {int? index}) => Chapter(
    itemId: _entryId(m),
    title: _entryTitle(m, index: index),
    volumeName: (m['volume_name'] ?? m['volumeName'] ?? '').toString(),
    version: (m['version'] ?? '').toString(),
  );
}

/// Explicit short-drama model used by the player and directory parser.
class Episode {
  final String itemId;
  final String title;
  final int index;
  final int durationSeconds;
  final bool trailer;
  final bool highlight;
  final bool disabled;
  final bool newlyUpdate;

  Episode({
    required this.itemId,
    required this.title,
    required this.index,
    this.durationSeconds = 0,
    this.trailer = false,
    this.highlight = false,
    this.disabled = false,
    this.newlyUpdate = false,
  });

  factory Episode.fromRaw(Map<String, dynamic> m, {int index = 0}) => Episode(
    itemId: _entryId(m),
    title: _entryTitle(m, index: index, fallbackPrefix: '第', suffix: '集'),
    index: _asInt(m['index'] ?? m['episode_index'] ?? m['episode_no']) ?? index,
    durationSeconds: _asInt(m['duration'] ?? m['duration_seconds']) ?? 0,
    // 官方字段名（`EpisodeInfo.java` 的 @SerializedName）：
    // 预告 = `is_preview_material`（`th3/e.java:119` 把它映射成
    // `SaasVideoData.isTrailer`）。
    trailer: _flag(m, const [
      'is_preview_material',
      'isPreviewMaterial',
      'is_trailer',
    ]),
    // `is_inserted_from_feed` **不是**接口字段：官方由客户端在插入推荐视频时
    // 自己 set（`wp3/a.java:42`、`yw2/j.java:34`），所以不从 JSON 里读。
    highlight: false,
    // item_status != 0 表示该集不可播（与 chapter_media.dart 对 item_status
    // 的处理同一含义）。
    // 官方 `EpisodeInfo.disable_play`（`th3/e.java:116`）；
    // 目录侧的 `item_status != 0` 是另一条等价信号。
    disabled:
        _flag(m, const ['disable_play', 'disablePlay']) ||
        (_asInt(m['item_status']) ?? 0) != 0,
    // 官方 `EpisodeInfo.is_newly_update`（`th3/e.java:133` 映射到
    // `SaasVideoData.isNewlyUpdate`，选集格子的「新」角标就看它）。
    newlyUpdate: _flag(m, const ['is_newly_update', 'isNewlyUpdate']),
  );

  Chapter toChapter() => Chapter(
    itemId: itemId,
    title: title,
    volumeName: '剧集',
    trailer: trailer,
    highlight: highlight,
    disabled: disabled,
    newlyUpdate: newlyUpdate,
  );
}

class SearchTab {
  final String title;
  final List<MediaItem> items;
  final bool? hasMore;
  final int? nextOffset;

  SearchTab({
    required this.title,
    required this.items,
    this.hasMore,
    this.nextOffset,
  });
}

/// Parses the normalized directory payload into chapter lists grouped by
/// volume. Both the app bridge shape and raw upstream shapes are accepted.
///
/// Note: the bridge's `chapterListWithVolume` entries carry no `version`, so it
/// is merged in from the raw `item_data_list` in the same payload — see
/// .agents/notes/implemented/feature/2026-09-11-reader-paragraph-bubble.md
List<List<Chapter>> parseDirectory(Map<String, dynamic> payload) {
  final versions = _directoryVersions(payload);
  final inner = _directoryInner(payload);
  if (inner is List) {
    final entries = _asMapList(inner);
    if (entries != null && entries.isNotEmpty) {
      final chapters = [
        for (var i = 0; i < entries.length; i++)
          Chapter.fromRaw(entries[i], index: i),
      ]
          .map((chapter) => _withVersion(chapter, versions))
          .where((chapter) => chapter.itemId.isNotEmpty)
          .toList();
      return chapters.isEmpty ? [] : [chapters];
    }
  }
  if (inner is! Map) return [];

  final volumes = <List<Chapter>>[];
  final volumeRaw = inner['chapterListWithVolume'];
  if (volumeRaw is List) {
    for (final volume in volumeRaw) {
      final rawChapters = _chapterListFromVolume(volume);
      if (rawChapters == null) continue;
      final volumeName = volume is Map
          ? (volume['volume_name'] ?? volume['volumeName'] ?? '').toString()
          : '';
      final chapters = <Chapter>[];
      for (var i = 0; i < rawChapters.length; i++) {
        final raw = rawChapters[i];
        final chapter = Chapter.fromRaw(raw, index: i);
        if (chapter.itemId.isEmpty) continue;
        chapters.add(
          Chapter(
            itemId: chapter.itemId,
            title: chapter.title,
            volumeName: chapter.volumeName.isEmpty
                ? volumeName
                : chapter.volumeName,
            version: _withVersion(chapter, versions).version,
          ),
        );
      }
      if (chapters.isNotEmpty) volumes.add(chapters);
    }
  }

  // Pseries responses are commonly returned as data.episodes.  The Go
  // bridge also exposes them under chapterListWithVolume, but accepting both
  // keeps the client compatible with older local binaries.
  if (volumes.isEmpty) {
    final found = _findDirectoryEntries(inner);
    if (found != null) {
      final chapters = <Chapter>[];
      for (var i = 0; i < found.entries.length; i++) {
        // `episodes` are drama-shaped (numbered, one implicit volume) while
        // `item_data_list` is novel-shaped and carries `volume_name` plus the
        // `version` the paragraph-comment endpoint needs. Reading a novel list
        // with the episode parser dropped both.
        final chapter = found.drama
            ? Episode.fromRaw(found.entries[i], index: i).toChapter()
            : Chapter.fromRaw(found.entries[i], index: i);
        if (chapter.itemId.isNotEmpty) {
          chapters.add(_withVersion(chapter, versions));
        }
      }
      if (chapters.isNotEmpty) volumes.add(chapters);
    }
  }
  return volumes;
}

/// Fills in a chapter's missing `version` from the raw `item_data_list` of the
/// same payload; the bridge-normalized entries omit it entirely.
Chapter _withVersion(Chapter chapter, Map<String, String> versions) =>
    chapter.version.isEmpty && versions[chapter.itemId]?.isNotEmpty == true
    ? Chapter(
        itemId: chapter.itemId,
        title: chapter.title,
        volumeName: chapter.volumeName,
        version: versions[chapter.itemId]!,
      )
    : chapter;

/// Indexes `item_id → version` from the first raw `item_data_list` found in
/// the payload. The normalized bridge chapters have no `version`, but the same
/// response always also embeds the raw upstream list, which does.
Map<String, String> _directoryVersions(dynamic value, [int depth = 0]) {
  final versions = <String, String>{};
  if (depth > 6 || value is! Map) return versions;
  final raw = value['item_data_list'];
  if (raw is List) {
    for (final entry in raw) {
      if (entry is! Map) continue;
      final id = (entry['item_id'] ?? entry['itemId'] ?? '').toString();
      final version = (entry['version'] ?? '').toString();
      if (id.isNotEmpty && version.isNotEmpty) versions[id] = version;
    }
    if (versions.isNotEmpty) return versions;
  }
  for (final child in value.values) {
    if (child is Map) versions.addAll(_directoryVersions(child, depth + 1));
  }
  return versions;
}

/// Directory entries plus whether they came from the drama-shaped `episodes`
/// key, so each shape can be read by the parser that understands it.
({List<Map<String, dynamic>> entries, bool drama})? _findDirectoryEntries(
  dynamic value, [
  int depth = 0,
]) {
  if (depth > 5 || value == null) return null;
  if (value is Map) {
    for (final key in ['episodes', 'item_data_list', 'lists', 'item_list']) {
      final found = _asMapList(value[key]);
      if (found != null && found.isNotEmpty) {
        return (entries: found, drama: key == 'episodes');
      }
    }
    for (final nested in value.values) {
      final found = _findDirectoryEntries(nested, depth + 1);
      if (found != null && found.entries.isNotEmpty) return found;
    }
  }
  return null;
}

/// Parses search payload into tabs and preserves parent metadata when video
/// results are nested in a `video_data` array. Search responses also contain
/// profile cards, related-query prompts and other UI-only cells; only nodes
/// with a real media identity belong in the media grid.
/// When [tabType] is requested, select that source before splitting manju so
/// another tab's results or pagination cannot leak into the requested page.
List<SearchTab> parseSearchTabs(Map<String, dynamic> payload, {int? tabType}) {
  // /api/search wraps its result in data; /api/v1/search returns the
  // upstream search_tabs object directly.
  final data = payload['data'] ?? payload;
  if (data is! Map) return [];
  final tabs = data['search_tabs'];
  if (tabs is! List) return [];

  final requestedTitle = const {1: '综合', 11: '短剧', 8: '漫画', 2: '听书'}[tabType];
  final selected = tabType == null
      ? tabs
      : tabs.where((tab) {
          if (tab is! Map) return false;
          final type = _asInt(tab['tab_type']);
          return type == tabType ||
              (type == null &&
                  requestedTitle != null &&
                  tab['title'] == requestedTitle);
        });
  final parsed = selected.map((rawTab) {
    if (rawTab is! Map) return SearchTab(title: '', items: []);
    final title = (requestedTitle ?? rawTab['title'] ?? '').toString();
    final rawItems = rawTab['data'];
    final items = <MediaItem>[];
    if (rawItems is List) {
      for (final rawItem in rawItems) {
        if (rawItem is! Map) continue;
        final item = Map<String, dynamic>.from(rawItem);
        final videoData = item['video_data'];
        if (videoData is List && videoData.isNotEmpty) {
          for (final child in videoData) {
            if (child is! Map) continue;
            final merged = Map<String, dynamic>.from(item);
            merged.addAll(Map<String, dynamic>.from(child));
            final media = MediaItem.fromRaw(merged);
            if (media.id.isNotEmpty) items.add(media);
          }
        } else if (item['book_data'] is List) {
          final before = items.length;
          for (final child in item['book_data'] as List) {
            if (child is! Map) continue;
            final book = Map<String, dynamic>.from(child);
            if (!_isSearchMediaNode({'book_data': book})) continue;
            final merged = Map<String, dynamic>.from(item)
              ..addAll(book)
              ..['book_data'] = book;
            final media = MediaItem.fromRaw(merged);
            if (media.id.isNotEmpty) items.add(media);
          }
          // Some legacy cells put the only ID on the parent and use
          // book_data solely for metadata. Keep that existing fallback.
          if (items.length == before && _isSearchMediaNode(item)) {
            final media = MediaItem.fromRaw(item);
            if (media.id.isNotEmpty) items.add(media);
          }
        } else if (_isSearchMediaNode(item)) {
          final media = MediaItem.fromRaw(item);
          if (media.id.isNotEmpty) items.add(media);
        }
      }
    }
    return SearchTab(
      title: title,
      items: items,
      hasMore: rawTab['has_more'] is bool ? rawTab['has_more'] as bool : null,
      nextOffset: _asInt(rawTab['next_offset']),
    );
  }).toList();
  return separateManjuSearchTabs(parsed);
}

/// The upstream searches manju in the short-drama tab. Keep a distinct app
/// filter without classifying unrelated matches by their search keyword.
List<SearchTab> separateManjuSearchTabs(List<SearchTab> tabs) {
  final manju = <MediaItem>[];
  final seen = <String>{};
  SearchTab? source;
  for (final tab in tabs) {
    if (tab.title == '短剧' || tab.title == '漫剧') source = tab;
    for (final item in tab.items) {
      if (item.kind == 'manju' && item.id.isNotEmpty && seen.add(item.id)) {
        manju.add(item);
      }
    }
  }
  if (source == null && manju.isEmpty) return tabs;
  final manjuTab = SearchTab(
    title: '漫剧',
    items: manju,
    hasMore: source?.hasMore,
    nextOffset: source?.nextOffset,
  );
  final result = <SearchTab>[];
  var inserted = false;
  for (final tab in tabs) {
    if (tab.title == '漫剧') continue;
    result.add(
      SearchTab(
        title: tab.title,
        items: const {'短剧', '小说', '书籍', '漫画', '听书'}.contains(tab.title)
            ? tab.items.where((item) => item.kind != 'manju').toList()
            : tab.items,
        hasMore: tab.hasMore,
        nextOffset: tab.nextOffset,
      ),
    );
    if (tab.title == '短剧') {
      result.add(manjuTab);
      inserted = true;
    }
  }
  if (!inserted) result.add(manjuTab);
  return result;
}

const _searchMediaIdKeys = <String>[
  'book_id',
  'video_id',
  'vid',
  'series_id',
  'pseries_id',
  'manga_id',
  'comic_id',
  'audio_book_id',
  'audio_id',
  'album_id',
  'item_id',
  'id',
];

const _searchMediaContentKeys = <String>[
  'title',
  'name',
  'raw_book_name',
  'book_name',
  'thumb_url',
  'cover',
  'cover_url',
  'poster',
  'author',
  'author_name',
];

bool _isSearchMediaNode(Map<String, dynamic> item) {
  bool hasValue(Map<dynamic, dynamic> candidate, String key) {
    final value = candidate[key];
    return value != null && value.toString().trim().isNotEmpty;
  }

  bool hasMediaId(Map<dynamic, dynamic> candidate) {
    return _searchMediaIdKeys.any((key) {
      if (!hasValue(candidate, key)) return false;
      final id = candidate[key].toString().trim();
      return id.isNotEmpty && id != '0';
    });
  }

  // A nested book_data container is an explicit media shape. UI-only cells
  // can carry misleading book_id values (for example the "社区" entry uses
  // book_id=104), so a top-level ID alone is not sufficient.
  final bookData = item['book_data'];
  if (bookData is Map && hasMediaId(bookData)) return true;
  if (bookData is Iterable) {
    if (bookData.any((value) => value is Map && hasMediaId(value))) {
      return true;
    }
  }

  // Keep compatibility with already-normalized/legacy flat search results,
  // but require actual media metadata as well as an ID.
  return hasMediaId(item) &&
      _searchMediaContentKeys.any((key) => hasValue(item, key));
}

/// Extracts media cards from recommendation and legacy endpoint responses.
/// It understands the nested `tab_item/cell_data/book_data` format as well as
/// search and directory-style lists.
List<MediaItem> parseMediaItems(Map<String, dynamic> payload, {String? kind}) {
  final root = payload['data'] ?? payload;
  final out = <MediaItem>[];
  final seen = <String>{};

  void add(Map<String, dynamic> raw) {
    final item = MediaItem.fromRaw({...raw, 'kind': ?kind});
    if (item.id.isEmpty) return;
    final key = '${item.kind}:${item.id}';
    if (seen.add(key)) out.add(item);
  }

  void visit(dynamic value, [int depth = 0]) {
    // The audio recommend feed (tab_type=5) nests book_data four cell_data
    // levels deep, so keep the recursion generous enough to reach it.
    if (depth > 14 || value == null) return;
    if (value is Iterable) {
      for (final child in value) {
        visit(child, depth + 1);
      }
      return;
    }
    if (value is! Map) return;
    final map = Map<String, dynamic>.from(value);

    // Search cells may have a parent plus nested video_data. Merge the parent
    // fields into each child so cover/title/category information is retained.
    final videoData = map['video_data'];
    if (videoData is Iterable && videoData.isNotEmpty) {
      for (final child in videoData) {
        if (child is Map) {
          // 短剧的模板卡（`show_type=407`）把标题/封面/简介放在更深一层的
          // `video_data[].video_detail`（`series_title`/`series_cover`/`series_intro`），
          // 扁平卡则直接放在 `video_data[]` 上。这里把 detail 也提上来，让
          // `MediaItem.fromRaw` 只在一个平面里找字段。
          final detail = child['video_detail'];
          final merged = Map<String, dynamic>.from(map)
            ..addAll(detail is Map ? Map<String, dynamic>.from(detail) : const {})
            ..addAll(Map<String, dynamic>.from(child));
          add(merged);
        }
      }
    }

    final hasIdentity = [
      'book_id',
      'video_id',
      'vid',
      'series_id',
      'pseries_id',
      'manga_id',
      'comic_id',
      'audio_book_id',
      'audio_id',
      'id',
      'item_id',
    ].any((key) => map[key] != null && map[key].toString().isNotEmpty);
    if (hasIdentity) add(map);

    for (final key in [
      'tab_item',
      'cell_data',
      // 官方短剧 feed 的第二段（`bookapi/bookmall/cell/change`）把卡片放在
      // `data.cell_view.cell_data[]` 里，比书城那层多包一个 `cell_view`。
      'cell_view',
      'book_data',
      'search_tabs',
      'data',
      'items',
      'lists',
      'item_data_list',
      'recommend_list',
    ]) {
      if (map.containsKey(key)) visit(map[key], depth + 1);
    }
  }

  visit(root);
  return out;
}

dynamic _directoryInner(Map<String, dynamic> payload) {
  dynamic data = payload['data'] ?? payload;
  if (data is Map && (data['data'] is Map || data['data'] is List)) {
    data = data['data'];
  }
  return data;
}

List<Map<String, dynamic>>? _chapterListFromVolume(dynamic volume) {
  if (volume is List) return _asMapList(volume);
  if (volume is Map) {
    final map = Map<String, dynamic>.from(volume);
    if (map['chapterList'] is List) return _asMapList(map['chapterList']);
    // Some older responses use a map keyed by chapter id.
    return map.values
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }
  return null;
}

List<Map<String, dynamic>>? _asMapList(dynamic value) {
  if (value is! List) return null;
  return value
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList();
}

String _entryId(Map<String, dynamic> m) {
  for (final key in [
    'itemId',
    'item_id',
    'chapter_id',
    'video_id',
    'vid',
    'episode_id',
    'id',
    'item_ids',
  ]) {
    final value = m[key];
    if (value is String && value.trim().isNotEmpty && value.trim() != '0') {
      return value.trim();
    }
    if (value is num && value != 0) return value.toString();
  }
  return '';
}

String _entryTitle(
  Map<String, dynamic> m, {
  int? index,
  String fallbackPrefix = '第',
  String suffix = '章',
}) {
  for (final key in [
    'title',
    'episode_title',
    'chapter_title',
    'name',
    'item_title',
  ]) {
    final value = m[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is Map) {
      final text = value['text'];
      if (text is String && text.trim().isNotEmpty) return text.trim();
    }
  }
  return '$fallbackPrefix${(index ?? 0) + 1}$suffix';
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

/// 布尔标记的宽松解析：上游可能给 bool、0/1 或 "true"/"1"。
bool _flag(Map<String, dynamic> m, List<String> keys) {
  for (final key in keys) {
    final value = m[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final text = value.trim().toLowerCase();
      if (text == 'true' || text == '1') return true;
    }
  }
  return false;
}

/// Category names for the info panel's chip row. The feed card's
/// `video_detail.secondary_infos` marks categories with `data_type == 3`
/// (other entries are actors and the like); `category_schema` — a JSON string
/// of `{name: …}` records, same shape the series detail page parses — is the
/// fallback when the card carries no secondary infos.
List<String> _secondaryCategories(dynamic secondaryInfos, {dynamic fallback}) {
  final names = <String>[];
  if (secondaryInfos is Iterable) {
    for (final entry in secondaryInfos) {
      if (entry is! Map) continue;
      final type = _asInt(entry['data_type']);
      final content = entry['content'];
      if (type == 3 && content is String && content.trim().isNotEmpty) {
        names.add(content.trim());
      }
    }
  }
  if (names.isEmpty && fallback is String && fallback.trim().isNotEmpty) {
    final matches = RegExp(
      '"name"\\s*:\\s*"([^"]+)"',
    ).allMatches(fallback);
    for (final match in matches) {
      final name = match.group(1)?.trim() ?? '';
      if (name.isNotEmpty) names.add(name);
    }
  }
  return List.unmodifiable(names);
}

extension MediaItemJson on MediaItem {
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'cover': cover,
    'author': author,
    'badge': badge,
    'ep': ep,
    'kind': kind,
    if (seriesId != null) 'seriesId': seriesId,
    if (episodeId != null) 'episodeId': episodeId,
    if (intro.isNotEmpty) 'intro': intro,
    if (followerCount > 0) 'followerCount': followerCount,
    if (categories.isNotEmpty) 'categories': categories,
    if (episodeListText.isNotEmpty) 'episodeListText': episodeListText,
    if (aiGenerated) 'aiGenerated': true,
    // The promotional badge must survive a round-trip; the keys reuse
    // [MediaTag.fromRaw]'s payload shape so both paths stay lossless.
    if (tag != null)
      'tag': {
        'text': tag!.text,
        'bg_color': tag!.lightColors,
        'dark_bg_color': tag!.darkColors,
      },
  };

  /// Restores what [toJson] wrote; `null` when required fields are missing.
  static MediaItem? fromJson(Map<String, dynamic> map) {
    String field(String key) => map[key]?.toString() ?? '';
    final id = field('id');
    final title = field('title');
    final kind = field('kind');
    if (id.isEmpty || title.isEmpty || kind.isEmpty) return null;
    return MediaItem(
      id: id,
      title: title,
      cover: field('cover'),
      author: field('author'),
      badge: field('badge'),
      ep: field('ep'),
      kind: kind,
      tag: MediaTag.fromRaw(map['tag'] is Map ? (map['tag'] as Map).cast<String, dynamic>() : null),
      seriesId: (map['seriesId'] as String?),
      episodeId: (map['episodeId'] as String?),
      intro: field('intro'),
      followerCount: _asInt(map['followerCount']) ?? 0,
      categories: map['categories'] is List
          ? List.unmodifiable(
              (map['categories'] as List).map((e) => '$e'),
            )
          : const [],
      episodeListText: field('episodeListText'),
      aiGenerated: map['aiGenerated'] == true,
    );
  }
}
