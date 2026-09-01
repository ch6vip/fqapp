/// Normalized media item used across the app.
///
/// Field mapping mirrors the Python frontend's `norm()` — the fanqie API
/// returns many different shapes depending on the content type, so we
/// normalize to a single structure here.
class MediaItem {
  final String id;
  final String title;
  final String cover;
  final String author;
  final String badge;
  final String ep;
  final String kind; // 'book' | 'video' | 'manga' | 'audio'

  MediaItem({
    required this.id,
    required this.title,
    required this.cover,
    required this.author,
    required this.badge,
    required this.ep,
    required this.kind,
  });

  factory MediaItem.fromRaw(Map<String, dynamic> item) {
    // Some search cells wrap the actual book in a book_data array.
    final rawBd = item['book_data'];
    Map<String, dynamic> bd;
    if (rawBd is List && rawBd.isNotEmpty && rawBd[0] is Map) {
      bd = Map<String, dynamic>.from(rawBd[0] as Map);
    } else if (rawBd is Map) {
      bd = Map<String, dynamic>.from(rawBd);
    } else {
      bd = item;
    }

    final titleObj = item['title'];
    final highlightTitle =
        _dig(item, ['search_high_light', 'title', 'text']) ?? _dig(titleObj, ['text']);

    final isVideo = _truthy(item['video_id']) ||
        _truthy(item['vid']) ||
        _truthy(item['video_platform']) ||
        _truthy(item['duration']);
    final isManga = !isVideo && _isMangaItem(item, bd);
    final isAudio = !isVideo && !isManga && _isAudioItem(item, bd);

    return MediaItem(
      id: _firstString(item, [
        'book_id',
      ]) ??
          _firstString(bd, ['book_id']) ??
          _firstString(item, [
            'video_id', 'vid', 'series_id', 'id', 'item_id', 'cell_id',
          ]) ??
          '',
      kind: isVideo ? 'video' : (isManga ? 'manga' : (isAudio ? 'audio' : 'book')),
      title: _firstString(item, ['cell_name']) ??
          highlightTitle ??
          _firstString(bd, ['book_name']) ??
          _firstString(item, [
            'book_name', 'title', 'name',
          ]) ??
          '未知',
      cover: _firstString(bd, ['thumb_url']) ??
          _firstString(item, [
            'thumb_url', 'cover', 'cover_url', 'poster',
          ]) ??
          _firstString(bd, ['cover_url']) ??
          '',
      author: _firstString(bd, ['author']) ??
          _firstString(item, ['author', 'author_name']) ??
          '',
      badge: _firstString(bd, ['category']) ??
          _firstString(item, [
            'category', 'type', 'cell_alias', 'card_tips',
          ]) ??
          '',
      ep: _firstString(item, [
        'serial_count', 'item_count', 'episode_count', 'episode_cnt',
      ]) ??
          _firstString(bd, ['serial_count']) ??
          '',
    );
  }

  static bool _truthy(dynamic v) => v != null && v != '' && v != 0;

  static String? _dig(dynamic v, List<String> keys) {
    dynamic cur = v;
    for (final k in keys) {
      if (cur is Map) {
        cur = cur[k];
      } else {
        return null;
      }
    }
    return cur is String && cur.isNotEmpty ? cur : null;
  }

  static String? _firstString(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is String && v.isNotEmpty) return v;
      if (v is num && v != 0) return v.toString();
    }
    return null;
  }

  static bool _isMangaItem(Map<String, dynamic> item, Map<String, dynamic> bd) {
    return _truthy(item['manga_id']) ||
        _truthy(item['comic_id']) ||
        _truthy(item['album_id']) ||
        _truthy(item['manga_type']) ||
        _truthy(bd['manga_id']) ||
        _truthy(bd['comic_id']);
  }

  static bool _isAudioItem(Map<String, dynamic> item, Map<String, dynamic> bd) {
    return _truthy(item['album_id']) ||
        _truthy(item['audio_book_id']) ||
        _truthy(item['audio_id']) ||
        _truthy(item['listen_book_id']) ||
        _truthy(bd['album_id']) ||
        _truthy(bd['audio_book_id']);
  }
}

/// A chapter entry in the directory (chapterListWithVolume format).
class Chapter {
  final String itemId;
  final String title;
  final String volumeName;

  Chapter({required this.itemId, required this.title, required this.volumeName});

  factory Chapter.fromRaw(Map<String, dynamic> m) => Chapter(
        itemId: (m['itemId'] ?? m['item_id'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
        volumeName: (m['volume_name'] ?? '').toString(),
      );
}

/// A search tab with its items.
class SearchTab {
  final String title;
  final List<MediaItem> items;

  SearchTab({required this.title, required this.items});
}

/// Parses the normalized directory payload into chapter lists grouped by volume.
List<List<Chapter>> parseDirectory(Map<String, dynamic> payload) {
  final data = payload['data'];
  if (data is! Map) return [];
  final inner = data['data'];
  if (inner is! Map) return [];
  final volList = inner['chapterListWithVolume'];
  if (volList is! List) return [];

  final out = <List<Chapter>>[];
  for (final v in volList) {
    if (v is! Map) continue;
    final chapters = <Chapter>[];
    // Support both chapterList and direct list-of-chapters shapes.
    final rawList = v['chapterList'] is List ? v['chapterList'] as List : null;
    if (rawList != null) {
      for (final c in rawList) {
        if (c is Map) chapters.add(Chapter.fromRaw(Map<String, dynamic>.from(c)));
      }
    } else {
      for (final c in v.values) {
        if (c is Map) chapters.add(Chapter.fromRaw(Map<String, dynamic>.from(c)));
      }
    }
    if (chapters.isNotEmpty) out.add(chapters);
  }
  return out;
}

/// Parses search payload into tabs.
List<SearchTab> parseSearchTabs(Map<String, dynamic> payload) {
  final data = payload['data'];
  if (data is! Map) return [];
  final tabs = data['search_tabs'];
  if (tabs is! List) return [];

  return tabs.map((t) {
    if (t is! Map) return SearchTab(title: '', items: []);
    final title = (t['title'] ?? '').toString();
    final rawItems = t['data'];
    final items = <MediaItem>[];
    if (rawItems is List) {
      for (final it in rawItems) {
        if (it is Map) {
          // video_data may be nested inside search cells
          final vd = it['video_data'];
          if (vd is List) {
            for (final v in vd) {
              if (v is Map) items.add(MediaItem.fromRaw(Map<String, dynamic>.from(v)));
            }
          } else {
            items.add(MediaItem.fromRaw(Map<String, dynamic>.from(it)));
          }
        }
      }
    }
    return SearchTab(title: title, items: items);
  }).toList();
}
