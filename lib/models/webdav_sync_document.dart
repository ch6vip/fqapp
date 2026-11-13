import 'dart:convert';
import 'dart:typed_data';

import '../services/shelf_store.dart';
import 'library_backup.dart';
import 'shelf_identity.dart';

/// Bookmarks/progress use the portable backup allowlist. Shelf removals carry
/// tombstones so an offline device cannot resurrect a removed favourite.
class WebDavSyncDocument {
  WebDavSyncDocument(this.backup, [Map<String, int>? removedShelf])
    : removedShelf = Map.of(removedShelf ?? const {});
  final LibraryBackup backup;
  final Map<String, int> removedShelf;

  Uint8List encode() {
    if (removedShelf.length > 10000) {
      throw const FormatException('移除记录超过 10000 条');
    }
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'fqapp.webdav-sync',
          'version': 1,
          'backup': jsonDecode(utf8.decode(backup.encode())),
          'removedShelf': removedShelf,
        }),
      ),
    );
  }

  factory WebDavSyncDocument.decode(Uint8List bytes) {
    if (bytes.length > 20 * 1024 * 1024) {
      throw const FormatException('同步文件超过 20 MB（DAV_SIZE）');
    }
    dynamic decoded;
    try {
      var text = utf8.decode(bytes);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('同步文件不是完整的 UTF-8 JSON（DAV_JSON）');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('同步文件根节点必须是 JSON 对象（DAV_ROOT）');
    }
    final raw = decoded;
    // A portable backup placed at the sync path is a known, validated legacy
    // representation; do not confuse it with an arbitrary JSON object.
    if (raw['format'] == 'fqapp.library-backup') {
      return WebDavSyncDocument(LibraryBackup.decode(bytes));
    }
    try {
      if (raw['format'] != 'fqapp.webdav-sync' || raw['version'] != 1) {
        throw const FormatException('不是兼容的 FQApp 同步文件（DAV_FORMAT）');
      }
      if (raw['backup'] is! Map<String, dynamic>) {
        throw const FormatException('同步文件缺少书架备份对象（DAV_BACKUP）');
      }
      final rawRemoved = raw['removedShelf'];
      if (rawRemoved != null && rawRemoved is! Map<String, dynamic>) {
        throw const FormatException('书架移除记录必须是对象（DAV_REMOVED）');
      }
      final removed = rawRemoved as Map<String, dynamic>? ?? const {};
      if (removed.length > 10000) throw const FormatException('移除记录过多');
      final tombstones = <String, int>{};
      for (final entry in removed.entries) {
        if (!entry.key.startsWith(ShelfIdentity.storagePrefix) ||
            ShelfIdentity.parseContentKey(
                  entry.key.substring(ShelfIdentity.storagePrefix.length),
                ) ==
                null ||
            entry.value is! int ||
            entry.value < 0 ||
            entry.value > 8640000000000000) {
          throw const FormatException('无效的书架移除记录');
        }
        tombstones[entry.key] = entry.value as int;
      }
      return WebDavSyncDocument(
        LibraryBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(raw['backup']))),
        ),
        tombstones,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('WebDAV 同步文件格式无效');
    }
  }

  WebDavSyncDocument merge(WebDavSyncDocument other) {
    final removed = Map.of(removedShelf);
    for (final entry in other.removedShelf.entries) {
      if (entry.value > (removed[entry.key] ?? -1)) {
        removed[entry.key] = entry.value;
      }
    }
    final shelf = <String, ShelfRecord>{};
    for (final record in [...backup.shelf, ...other.backup.shelf]) {
      final key = ShelfStore.keyOf(record.item);
      final time = record.addedAt.millisecondsSinceEpoch;
      if (time <= (removed[key] ?? -1)) continue;
      if (time > (shelf[key]?.addedAt.millisecondsSinceEpoch ?? -1)) {
        shelf[key] = record;
      }
    }
    final history = <String, Map<String, dynamic>>{};
    for (final record in [...backup.history, ...other.backup.history]) {
      final key = '${record['kind']}:${record['id']}';
      final previous = history[key];
      final time = (record['time'] as int?) ?? 0;
      final oldTime = (previous?['time'] as int?) ?? 0;
      if (previous == null ||
          time > oldTime ||
          (time == oldTime &&
              jsonEncode(record).compareTo(jsonEncode(previous)) > 0)) {
        history[key] = record;
      }
    }
    final watched = <String, Map<String, int>>{};
    for (final source in [backup.watched, other.backup.watched]) {
      for (final entry in source.entries) {
        final target = watched.putIfAbsent(entry.key, () => {});
        for (final episode in entry.value.entries) {
          if (episode.value > (target[episode.key] ?? -1)) {
            target[episode.key] = episode.value;
          }
        }
      }
    }
    return WebDavSyncDocument(
      LibraryBackup.capture(
        shelf: shelf.values.toList(),
        history: history.values.toList(),
        watched: watched,
        aiData: backup.aiData ?? other.backup.aiData,
        groups: backup.groups.isNotEmpty ? backup.groups : other.backup.groups,
      ),
      removed,
    );
  }
}
