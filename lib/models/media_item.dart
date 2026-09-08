/// Normalized content models used by the Flutter client.
///
/// The upstream service returns different field names for novels, short
/// dramas, comics and audio books.  Keep that compatibility code here so the
/// pages only deal with stable, typed values.
library;

import 'dart:isolate';

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
  final String kind; // 'book' | 'video' | 'manga' | 'audio'
  /// For short dramas, seriesId is the ID accepted by the pseries directory
  /// endpoint and episodeId is an optional individual video ID.
  final String? seriesId;
  final String? episodeId;

  MediaItem({
    required this.id,
    required this.title,
    required this.cover,
    required this.author,
    required this.badge,
    required this.ep,
    required this.kind,
    this.seriesId,
    this.episodeId,
  });

  factory MediaItem.fromRaw(Map<String, dynamic> item) {
    final bd = _mapFrom(item['book_data']) ?? item;
    final titleObj = item['title'];
    final highlightTitle =
        _dig(item, ['search_high_light', 'title', 'text']) ??
        _dig(titleObj, ['text']);

    final explicitKind = _normalizeKind(item['kind']);
    final kind = explicitKind.isNotEmpty
        ? explicitKind
        : _isVideoItem(item, bd)
        ? 'video'
        : _isMangaItem(item, bd)
        ? 'manga'
        : _isAudioItem(item, bd)
        ? 'audio'
        : 'book';

    final seriesKeys = <String>['pseries_id', 'series_id'];
    // A search cell can wrap episodes in video_data and expose the series
    // identifier only as its book_id. A standalone video result should keep
    // its video_id instead, because that is what /api/content accepts.
    if (item['video_data'] is List) seriesKeys.add('book_id');
    final seriesId = kind == 'video'
        ? (_firstString(item, ['seriesId']) ??
              _firstString(item, seriesKeys) ??
              _firstString(bd, seriesKeys))
        : null;
    final episodeId = kind == 'video'
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
      'video' => [
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

    return MediaItem(
      id:
          seriesId ??
          _firstString(bd, idKeys) ??
          _firstString(item, idKeys) ??
          '',
      kind: kind,
      seriesId: seriesId,
      episodeId: episodeId,
      title:
          highlightTitle ??
          _firstString(item, ['title', 'name', 'raw_book_name']) ??
          _firstString(bd, ['title', 'name', 'raw_book_name', 'book_name']) ??
          _firstString(item, ['book_name']) ??
          _firstString(item, ['cell_name']) ??
          '未知',
      cover:
          _firstString(item, ['thumb_url', 'cover', 'cover_url', 'poster']) ??
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
    return _truthyAny(item, [
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

  static String _normalizeKind(dynamic value) {
    final raw = value?.toString().trim().toLowerCase() ?? '';
    switch (raw) {
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

/// A text chapter or short-drama episode in a directory.
class Chapter {
  final String itemId;
  final String title;
  final String volumeName;

  Chapter({
    required this.itemId,
    required this.title,
    required this.volumeName,
  });

  factory Chapter.fromRaw(Map<String, dynamic> m, {int? index}) => Chapter(
    itemId: _entryId(m),
    title: _entryTitle(m, index: index),
    volumeName: (m['volume_name'] ?? m['volumeName'] ?? '').toString(),
  );
}

/// Explicit short-drama model used by the player and directory parser.
class Episode {
  final String itemId;
  final String title;
  final int index;
  final int durationSeconds;

  Episode({
    required this.itemId,
    required this.title,
    required this.index,
    this.durationSeconds = 0,
  });

  factory Episode.fromRaw(Map<String, dynamic> m, {int index = 0}) => Episode(
    itemId: _entryId(m),
    title: _entryTitle(m, index: index, fallbackPrefix: '第', suffix: '集'),
    index: _asInt(m['index'] ?? m['episode_index'] ?? m['episode_no']) ?? index,
    durationSeconds: _asInt(m['duration'] ?? m['duration_seconds']) ?? 0,
  );

  Chapter toChapter() =>
      Chapter(itemId: itemId, title: title, volumeName: '剧集');
}

class SearchTab {
  final String title;
  final List<MediaItem> items;

  SearchTab({required this.title, required this.items});
}

/// Parses the normalized directory payload into chapter lists grouped by
/// volume. Both the app bridge shape and raw upstream shapes are accepted.
List<List<Chapter>> parseDirectory(Map<String, dynamic> payload) {
  final inner = _directoryInner(payload);
  if (inner is List) {
    final entries = _asMapList(inner);
    if (entries != null && entries.isNotEmpty) {
      final chapters = [
        for (var i = 0; i < entries.length; i++)
          Chapter.fromRaw(entries[i], index: i),
      ].where((chapter) => chapter.itemId.isNotEmpty).toList();
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
    final episodes = _findDirectoryEntries(inner);
    if (episodes != null) {
      final chapters = <Chapter>[];
      for (var i = 0; i < episodes.length; i++) {
        final chapter = Episode.fromRaw(episodes[i], index: i).toChapter();
        if (chapter.itemId.isNotEmpty) chapters.add(chapter);
      }
      if (chapters.isNotEmpty) volumes.add(chapters);
    }
  }
  return volumes;
}

List<Map<String, dynamic>>? _findDirectoryEntries(
  dynamic value, [
  int depth = 0,
]) {
  if (depth > 5 || value == null) return null;
  if (value is Map) {
    for (final key in ['episodes', 'item_data_list', 'lists', 'item_list']) {
      final found = _asMapList(value[key]);
      if (found != null && found.isNotEmpty) return found;
    }
    for (final nested in value.values) {
      final found = _findDirectoryEntries(nested, depth + 1);
      if (found != null && found.isNotEmpty) return found;
    }
  }
  return null;
}

/// Parses search payload into tabs and preserves parent metadata when video
/// results are nested in a `video_data` array. Search responses also contain
/// profile cards, related-query prompts and other UI-only cells; only nodes
/// with a real media identity belong in the media grid.
List<SearchTab> parseSearchTabs(Map<String, dynamic> payload) {
  // /api/search wraps its result in data; /api/v1/search returns the
  // upstream search_tabs object directly.
  final data = payload['data'] ?? payload;
  if (data is! Map) return [];
  final tabs = data['search_tabs'];
  if (tabs is! List) return [];

  return tabs.map((rawTab) {
    if (rawTab is! Map) return SearchTab(title: '', items: []);
    final title = (rawTab['title'] ?? '').toString();
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
    return SearchTab(title: title, items: items);
  }).toList();
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
List<MediaItem> parseMediaItems(Map<String, dynamic> payload) {
  final root = payload['data'] ?? payload;
  final out = <MediaItem>[];
  final seen = <String>{};

  void add(Map<String, dynamic> raw) {
    final item = MediaItem.fromRaw(raw);
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
          final merged = Map<String, dynamic>.from(map)
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
  };
}
