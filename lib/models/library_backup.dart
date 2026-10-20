import 'dart:convert';
import 'dart:typed_data';

import '../services/shelf_store.dart';
import 'media_item.dart';

/// A portable allowlist, never a dump of Hive boxes or device preferences.
// Note: 范围、合并规则与非事务恢复见
// .agents/notes/implemented/feature/2026-10-15-library-backup.md
class LibraryBackup {
  static const maxBytes = 16 * 1024 * 1024;
  static const _maxRecords = 10000;
  static const _maxEpisodes = 100000;
  static const _format = 'fqapp.library-backup';
  static const _kinds = {'book', 'audio', 'manga', 'video', 'manju'};
  static final _idPattern = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');

  final DateTime createdAt;
  final List<ShelfRecord> shelf;

  /// IDs here are content IDs. Storage keys are reconstructed by LibraryStore.
  final List<Map<String, dynamic>> history;
  final Map<String, Map<String, int>> watched;
  final int excludedLocalRecords;

  LibraryBackup._({
    required this.createdAt,
    required this.shelf,
    required this.history,
    required this.watched,
    required this.excludedLocalRecords,
  });

  int get episodeCount =>
      watched.values.fold(0, (total, episodes) => total + episodes.length);

  factory LibraryBackup.capture({
    required List<ShelfRecord> shelf,
    required List<Map<String, dynamic>> history,
    required Map<String, Map<String, int>> watched,
  }) {
    var excluded = 0;
    bool include(String id) {
      if (!id.startsWith('local_')) return true;
      excluded++;
      return false;
    }

    // The same validation is used before export and before any restore writes.
    return LibraryBackup._fromJson({
      'format': _format,
      'version': 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'shelf': [
        for (final record in shelf)
          if (include(record.item.seriesId ?? record.item.id))
            {..._shelfJson(record), 'cover': _portableCover(record.item.cover)},
      ],
      'history': [
        for (final record in history)
          if (include((record['contentId'] ?? record['id']).toString()))
            {
              ...record,
              'id': record['contentId'] ?? record['id'],
              'kind': record['kind'] ?? 'book',
              'cover': _portableCover(record['cover']?.toString() ?? ''),
            },
      ],
      'watched': [
        for (final entry in watched.entries)
          if (include(entry.key)) {'id': entry.key, 'episodes': entry.value},
      ],
      'excludedLocalRecords': excluded,
    });
  }

  factory LibraryBackup.decode(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('备份文件超过 16 MB');
    }
    dynamic raw;
    try {
      var text = utf8.decode(bytes);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      raw = jsonDecode(text);
    } on FormatException {
      throw const FormatException('文件不是有效的 UTF-8 JSON 备份');
    }
    return LibraryBackup._fromJson(_map(raw));
  }

  factory LibraryBackup._fromJson(Map<String, dynamic> raw) {
    if (raw['format'] != _format || raw['version'] != 1) {
      throw const FormatException('不是受支持的 FQApp 备份，请使用兼容版本导出的文件');
    }
    final createdAt = _integer(raw['createdAt'], '备份时间', 8640000000000000);
    final shelf = <ShelfRecord>[];
    final shelfKeys = <String>{};
    for (final value in _list(raw['shelf'])) {
      final record = _map(value);
      final common = _common(record);
      final item = MediaItem(
        id: common['id'] as String,
        kind: common['kind'] as String,
        title: common['title'] as String,
        cover: common['cover'] as String,
        author: common['author'] as String,
        badge: common['badge'] as String,
        ep: common['ep'] as String,
        seriesId: common['seriesId'] as String?,
        episodeId: common['episodeId'] as String?,
      );
      if (!shelfKeys.add(ShelfStore.keyOf(item))) {
        throw const FormatException('备份中有重复的收藏');
      }
      shelf.add(
        ShelfRecord(
          item: item,
          addedAt: DateTime.fromMillisecondsSinceEpoch(
            _integer(record['addedAt'], '收藏时间', 8640000000000000),
          ),
        ),
      );
    }
    final history = <Map<String, dynamic>>[];
    final historyKeys = <String>{};
    for (final value in _list(raw['history'])) {
      final record = _map(value);
      final clean = _common(record);
      if (!historyKeys.add('${clean['kind']}:${clean['id']}')) {
        throw const FormatException('备份中有重复的进度');
      }
      for (final key in ['bookId', 'chapterId', 'toneId']) {
        if (record[key] != null && record[key] != '') {
          clean[key] = _id(record[key]);
        }
      }
      for (final key in ['time', 'episode', 'positionVersion', 'textOffset']) {
        if (record[key] != null) {
          clean[key] = _integer(
            record[key],
            key,
            key == 'time' ? 8640000000000000 : 2147483647,
          );
        }
      }
      for (final key in [
        'position',
        'maxScroll',
        'progress',
        'duration',
        'rate',
      ]) {
        if (record[key] == null) continue;
        final value = record[key];
        final max = key == 'progress'
            ? 1
            : key == 'rate'
            ? 10
            : 1e12;
        if (value is! num || !value.isFinite || value < 0 || value > max) {
          throw FormatException('备份字段 $key 无效');
        }
        clean[key] = value.toDouble();
      }
      if (record['positionUnit'] != null) {
        if (record['positionUnit'] != 'comic-page' ||
            clean['kind'] != 'manga') {
          throw const FormatException('不支持的漫画进度单位');
        }
        clean['positionUnit'] = 'comic-page';
      }
      for (final key in ['autoAdvance', 'completed', 'fanqieImported']) {
        if (record[key] == null) continue;
        if (record[key] is! bool) throw FormatException('备份字段 $key 无效');
        clean[key] = record[key];
      }
      history.add(Map.unmodifiable(clean));
    }
    final watched = <String, Map<String, int>>{};
    var count = 0;
    for (final value in _list(raw['watched'])) {
      final record = _map(value);
      final id = _id(record['id']);
      if (watched.containsKey(id)) throw const FormatException('备份中有重复的已看记录');
      final episodes = _map(record['episodes']);
      count += episodes.length;
      if (count > _maxEpisodes) throw const FormatException('已看剧集超过 100000 条');
      watched[id] = Map.unmodifiable({
        for (final entry in episodes.entries)
          _id(entry.key): _integer(entry.value, '已看时间', 8640000000000000),
      });
    }
    return LibraryBackup._(
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      shelf: List.unmodifiable(shelf),
      history: List.unmodifiable(history),
      watched: Map.unmodifiable(watched),
      excludedLocalRecords: _integer(
        raw['excludedLocalRecords'] ?? 0,
        '排除条数',
        2147483647,
      ),
    );
  }

  Uint8List encode() {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': _format,
          'version': 1,
          'createdAt': createdAt.millisecondsSinceEpoch,
          'shelf': shelf.map(_shelfJson).toList(),
          'history': history,
          'watched': [
            for (final entry in watched.entries)
              {'id': entry.key, 'episodes': entry.value},
          ],
          'excludedLocalRecords': excludedLocalRecords,
        }),
      ),
    );
    if (bytes.length > maxBytes) throw const FormatException('备份数据超过 16 MB');
    return bytes;
  }

  static Map<String, dynamic> _shelfJson(ShelfRecord record) => {
    'id': record.item.id,
    'kind': record.item.kind,
    'title': record.item.title,
    'cover': record.item.cover,
    'author': record.item.author,
    'badge': record.item.badge,
    'ep': record.item.ep,
    if (record.item.seriesId != null) 'seriesId': record.item.seriesId,
    if (record.item.episodeId != null) 'episodeId': record.item.episodeId,
    'addedAt': record.addedAt.millisecondsSinceEpoch,
  };

  static Map<String, dynamic> _common(Map<String, dynamic> raw) {
    if (!_kinds.contains(raw['kind'])) throw const FormatException('备份含未知作品类型');
    final clean = <String, dynamic>{'id': _id(raw['id']), 'kind': raw['kind']};
    for (final key in ['title', 'cover', 'author', 'badge', 'ep']) {
      final value = raw[key] ?? '';
      if (value is! String || value.length > 8192) {
        throw FormatException('备份字段 $key 无效或过长');
      }
      clean[key] = key == 'cover' ? _portableCover(value) : value;
    }
    for (final key in ['seriesId', 'episodeId']) {
      if (raw[key] != null && raw[key] != '') clean[key] = _id(raw[key]);
    }
    return clean;
  }

  static String _portableCover(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? value
        : '';
  }

  static String _id(dynamic value) {
    if (value is! String ||
        !_idPattern.hasMatch(value) ||
        value.startsWith('local_')) {
      throw const FormatException('备份含无效作品标识或本地书籍记录');
    }
    return value;
  }

  static int _integer(dynamic value, String label, int max) {
    if (value is! int || value < 0 || value > max) {
      throw FormatException('备份字段 $label 无效');
    }
    return value;
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is! Map<String, dynamic>) throw const FormatException('备份记录格式无效');
    return value;
  }

  static List<dynamic> _list(dynamic value) {
    if (value is! List || value.length > _maxRecords) {
      throw const FormatException('备份列表无效或超过 10000 条');
    }
    return value;
  }
}
