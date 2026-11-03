import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_ce/hive.dart';

import 'app_log.dart';
import 'chapter_cache_bytes.dart';
import 'encrypted_hive.dart';

enum ChapterCacheCommand {
  read,
  write,
  saveBook,
  cachedChapterIds,
  stats,
  books,
  cachedBook,
  savedCatalogue,
  clear,
  close,
}

/// Used only by the cache worker, which serializes every command.
class ChapterCacheStorage {
  ChapterCacheStorage({
    required this.encryptionKey,
    required this.maxEntries,
    required this.maxBytes,
    required this.catalogTtl,
  });

  static const _bodyName = 'chapter_cache_v1';
  static const _catalogName = 'chapter_cache_catalog_v1';
  static const _versionKey = 'meta:catalogue_version';
  static const _dirtyKey = 'meta:body_write_pending';
  static const _catalogVersion = 2;

  final Uint8List encryptionKey;
  final int maxEntries;
  final int maxBytes;
  final Duration catalogTtl;
  final _byteCounter = ChapterCacheByteCounter();
  final _index = <String, Map<String, _ChapterEntry>>{};
  final _bookBytes = <String, int>{};
  Future<LazyBox<dynamic>>? _opening;
  Future<Box<dynamic>>? _catalogOpening;
  bool _catalogReady = false;
  int _lastAccessTime = 0;

  int get textEncodes => _byteCounter.encodes;

  Future<dynamic> execute(
    ChapterCacheCommand command,
    Map<String, dynamic> args,
  ) async {
    if (command == ChapterCacheCommand.close) {
      await Hive.close();
      return null;
    }
    final catalog = await _catalogBox();
    return switch (command) {
      ChapterCacheCommand.read => _read(catalog, args),
      ChapterCacheCommand.write => _write(catalog, args),
      ChapterCacheCommand.saveBook => _saveBook(catalog, args),
      ChapterCacheCommand.cachedChapterIds =>
        _index[args['bookId']]?.keys.toList() ?? <String>[],
      ChapterCacheCommand.stats => _stats(args['bookId'] as String?),
      ChapterCacheCommand.books => _books(catalog),
      ChapterCacheCommand.cachedBook =>
        _index.containsKey(args['bookId'])
            ? _book(catalog, args['bookId'] as String)
            : null,
      ChapterCacheCommand.savedCatalogue => catalog.get(
        'book:${args['bookId']}',
      ),
      ChapterCacheCommand.clear => _clear(catalog, args['bookId'] as String?),
      ChapterCacheCommand.close => null,
    };
  }

  Future<LazyBox<dynamic>> _box() async {
    try {
      final box = await (_opening ??= EncryptedHive.openLazyBox<dynamic>(
        Hive,
        _bodyName,
        encryptionKey: encryptionKey,
        requireEncryption: true,
        compactionStrategy: (entries, deleted) =>
            deleted >= 50 && deleted > entries ~/ 2,
      ));
      if (box.isOpen) return box;
      _opening = null;
      return _box();
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<Box<dynamic>> _catalogBox() async {
    try {
      final box = await (_catalogOpening ??= EncryptedHive.openBox<dynamic>(
        Hive,
        _catalogName,
        encryptionKey: encryptionKey,
        requireEncryption: true,
        compactionStrategy: (entries, deleted) =>
            deleted >= 50 && deleted > entries ~/ 2,
      ));
      if (!box.isOpen) {
        _catalogOpening = null;
        _catalogReady = false;
        return _catalogBox();
      }
      if (!_catalogReady) {
        if (box.get(_versionKey) != _catalogVersion ||
            box.get(_dirtyKey) == true ||
            !_restoreIndex(box)) {
          await _rebuildCatalogue(box);
        }
        _catalogReady = true;
      }
      return box;
    } catch (_) {
      _catalogOpening = null;
      _catalogReady = false;
      rethrow;
    }
  }

  bool _restoreIndex(Box<dynamic> catalog) {
    _index.clear();
    _bookBytes.clear();
    for (final key in catalog.keys) {
      if (key is! String || !key.startsWith('chapter:')) continue;
      final entry = _ChapterEntry.fromMap(catalog.get(key));
      if (entry == null || entry.key != key) return false;
      _putIndex(entry);
    }
    return true;
  }

  void _putIndex(_ChapterEntry entry) {
    final chapters = _index.putIfAbsent(entry.bookId, () => {});
    final previous = chapters[entry.chapterId];
    chapters[entry.chapterId] = entry;
    _bookBytes[entry.bookId] =
        (_bookBytes[entry.bookId] ?? 0) + entry.bytes - (previous?.bytes ?? 0);
  }

  void _removeIndex(_ChapterEntry entry) {
    final chapters = _index[entry.bookId];
    final removed = chapters?.remove(entry.chapterId);
    if (removed == null) return;
    if (chapters!.isEmpty) {
      _index.remove(entry.bookId);
      _bookBytes.remove(entry.bookId);
    } else {
      _bookBytes[entry.bookId] = _bookBytes[entry.bookId]! - removed.bytes;
    }
  }

  int _now() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return _lastAccessTime = now > _lastAccessTime ? now : _lastAccessTime + 1;
  }

  Future<String?> _read(Box<dynamic> catalog, Map<String, dynamic> args) async {
    final bookId = args['bookId'] as String;
    final chapterId = args['chapterId'] as String;
    final key = _chapterKey(bookId, chapterId);
    final data = await _box();
    final raw = await data.get(key);
    if (!_isChapter(raw, bookId, chapterId)) return null;
    final previous = _index[bookId]?[chapterId];
    if (previous != null) {
      final touched = previous.touch(_now());
      _putIndex(touched);
      if (touched.accessedAt - _accessedAt(catalog.get(key)) >=
          const Duration(hours: 1).inMicroseconds) {
        try {
          await catalog.put(key, touched.toMap());
        } catch (_) {
          // A failed LRU timestamp update must not hide readable text.
        }
      }
    }
    return raw['text'] as String;
  }

  Future<void> _write(Box<dynamic> catalog, Map<String, dynamic> args) async {
    final bookId = args['bookId'] as String;
    final chapterId = args['chapterId'] as String;
    final text = args['text'] as String;
    if (bookId.isEmpty || chapterId.isEmpty || text.trim().isEmpty) return;
    final bytes = utf8.encode(text).length;
    if (bytes > maxBytes) {
      throw StateError(
        '\u8be5\u7ae0\u8282\u8d85\u8fc7\u7f13\u5b58\u5bb9\u91cf\u4e0a\u9650',
      );
    }
    final entry = _ChapterEntry(
      bookId: bookId,
      chapterId: chapterId,
      title: args['title'] as String,
      bytes: bytes,
      pinned:
          args['pinned'] == true || _index[bookId]?[chapterId]?.pinned == true,
      accessedAt: _now(),
    );
    await _mutate(catalog, (data) async {
      await data.put(entry.key, {...entry.toMap(), 'text': text});
      await catalog.put(entry.key, entry.toMap());
      _putIndex(entry);
      if (!entry.pinned) await _trim(data, catalog);
      await _sweepCatalogues(catalog, keepBook: bookId);
    });
  }

  Future<void> _mutate(
    Box<dynamic> catalog,
    Future<void> Function(LazyBox<dynamic>) action,
  ) async {
    final data = await _box();
    try {
      // The two boxes have no shared transaction. Persist the repair marker
      // before touching bodies; clear it only after both sides are durable.
      await catalog.put(_dirtyKey, true);
      await catalog.flush();
      await action(data);
      await data.flush();
      await catalog.delete(_dirtyKey);
      await catalog.flush();
    } catch (_) {
      _catalogReady = false;
      rethrow;
    }
  }

  Future<void> _saveBook(
    Box<dynamic> catalog,
    Map<String, dynamic> record,
  ) async {
    final id = record['id'] as String;
    if (id.isEmpty || (record['chapters'] as List).isEmpty) return;
    await catalog.put('book:$id', {
      ...record,
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await _sweepCatalogues(catalog, keepBook: id);
  }

  Map<String, int> _stats(String? bookId) => {
    'chapterCount': bookId == null
        ? _index.values.fold(0, (total, chapters) => total + chapters.length)
        : _index[bookId]?.length ?? 0,
    'byteCount': bookId == null
        ? _bookBytes.values.fold(0, (total, bytes) => total + bytes)
        : _bookBytes[bookId] ?? 0,
  };

  Map<String, dynamic>? _book(Box<dynamic> catalog, String bookId) {
    final raw = catalog.get('book:$bookId');
    if (raw is Map &&
        raw['chapters'] is List &&
        (raw['chapters'] as List).isNotEmpty) {
      return _stringMap(raw);
    }
    final entries = _index[bookId];
    if (entries == null) return null;
    return {
      'id': bookId,
      'title': raw is Map ? raw['title'] ?? bookId : bookId,
      'cover': raw is Map ? raw['cover'] ?? '' : '',
      'chapters': [
        for (final entry in entries.values)
          {
            'itemId': entry.chapterId,
            'title': entry.title,
            'volumeName': '',
            'version': '',
          },
      ],
    };
  }

  List<Map<String, dynamic>> _books(Box<dynamic> catalog) {
    final ids = _index.keys.toList();
    int lastAccess(String id) => _index[id]!.values.fold(
      0,
      (latest, entry) => entry.accessedAt > latest ? entry.accessedAt : latest,
    );
    final access = {for (final id in ids) id: lastAccess(id)};
    ids.sort((a, b) => access[b]!.compareTo(access[a]!));
    return [
      for (final id in ids) {'book': _book(catalog, id), 'stats': _stats(id)},
    ];
  }

  Future<void> _clear(Box<dynamic> catalog, String? bookId) async {
    await _mutate(catalog, (data) async {
      if (bookId == null) {
        await data.clear();
        await catalog.deleteAll([
          for (final key in catalog.keys)
            if (key is String &&
                (key.startsWith('book:') || key.startsWith('chapter:')))
              key,
        ]);
        _index.clear();
        _bookBytes.clear();
      } else {
        final keys = [
          for (final key in data.keys)
            if (_chapterKeyParts(key)?.$1 == bookId) key,
        ];
        await data.deleteAll(keys);
        await catalog.deleteAll([
          'book:$bookId',
          for (final entry in _index[bookId]?.values ?? <_ChapterEntry>[])
            entry.key,
        ]);
        _index.remove(bookId);
        _bookBytes.remove(bookId);
      }
      await data.compact();
      await catalog.compact();
    });
  }

  Future<void> _trim(LazyBox<dynamic> data, Box<dynamic> catalog) async {
    final entries = [
      for (final book in _index.values)
        for (final entry in book.values)
          if (!entry.pinned) entry,
    ];
    var bytes = entries.fold(0, (total, entry) => total + entry.bytes);
    if (entries.length <= maxEntries && bytes <= maxBytes) return;
    entries.sort((a, b) => a.accessedAt.compareTo(b.accessedAt));
    var remaining = entries.length;
    final removed = <_ChapterEntry>[];
    for (final entry in entries) {
      if (remaining <= maxEntries && bytes <= maxBytes) break;
      removed.add(entry);
      remaining--;
      bytes -= entry.bytes;
    }
    final keys = [for (final entry in removed) entry.key];
    await data.deleteAll(keys);
    await catalog.deleteAll(keys);
    for (final entry in removed) {
      _removeIndex(entry);
    }
  }

  Future<void> _sweepCatalogues(
    Box<dynamic> catalog, {
    required String keepBook,
  }) async {
    final detached = <({String key, int cachedAt})>[];
    for (final key in catalog.keys) {
      if (key is! String || !key.startsWith('book:')) continue;
      if (_index.containsKey(key.substring(5))) continue;
      final raw = catalog.get(key);
      detached.add((
        key: key,
        cachedAt: raw is Map && raw['cachedAt'] is int ? raw['cachedAt'] : 0,
      ));
    }
    detached.sort((a, b) => a.cachedAt.compareTo(b.cachedAt));
    final now = DateTime.now().millisecondsSinceEpoch;
    final doomed = <String>{};
    var remaining = detached.length;
    for (final record in detached) {
      if (record.key != 'book:$keepBook' &&
          now - record.cachedAt >= catalogTtl.inMilliseconds) {
        doomed.add(record.key);
        remaining--;
      }
    }
    for (final record in detached) {
      if (remaining <= maxEntries) break;
      if (record.key == 'book:$keepBook' || doomed.contains(record.key)) {
        continue;
      }
      doomed.add(record.key);
      remaining--;
    }
    if (doomed.isNotEmpty) await catalog.deleteAll(doomed);
  }

  Future<void> _rebuildCatalogue(Box<dynamic> catalog) async {
    final stopwatch = Stopwatch()..start();
    AppLog.i(
      'chapter-cache',
      'Rebuilding the chapter index in the cache worker',
    );
    await catalog.put(_dirtyKey, true);
    await catalog.flush();
    final books = <String, Map<String, dynamic>>{};
    for (final key in catalog.keys) {
      if (key is! String || !key.startsWith('book:')) continue;
      final raw = catalog.get(key);
      if (raw is Map) books[key] = _cleanBook(raw);
    }
    _index.clear();
    _bookBytes.clear();
    final exists =
        await Hive.boxExists(EncryptedHive.encryptedBoxName(_bodyName)) ||
        await Hive.boxExists(_bodyName);
    final data = exists ? await _box() : null;
    final legacyBookKeys = <String>[];
    if (data != null) {
      for (final key in data.keys.toList()) {
        if (key is String && key.startsWith('book:')) {
          final raw = await data.get(key);
          if (raw is Map) books.putIfAbsent(key, () => _cleanBook(raw));
          legacyBookKeys.add(key);
          continue;
        }
        final parts = _chapterKeyParts(key);
        if (parts == null) continue;
        final raw = await data.get(key);
        if (!_isChapter(raw, parts.$1, parts.$2)) continue;
        final bodyTime = _accessedAt(raw);
        final indexTime = _accessedAt(catalog.get(key));
        _putIndex(
          _ChapterEntry(
            bookId: parts.$1,
            chapterId: parts.$2,
            title: raw['title']?.toString() ?? '',
            bytes: _byteCounter.bytesOf(raw as Map),
            pinned: raw['pinned'] == true,
            accessedAt: bodyTime > indexTime ? bodyTime : indexTime,
          ),
        );
      }
    }
    await catalog.deleteAll([
      for (final key in catalog.keys)
        if (key is String && key.startsWith('chapter:')) key,
    ]);
    if (books.isNotEmpty) await catalog.putAll(books);
    final batch = <String, dynamic>{};
    for (final book in _index.values) {
      for (final entry in book.values) {
        batch[entry.key] = entry.toMap();
        if (batch.length >= 64) {
          await catalog.putAll(batch);
          batch.clear();
        }
      }
    }
    if (batch.isNotEmpty) await catalog.putAll(batch);
    await catalog.flush();
    if (data != null && legacyBookKeys.isNotEmpty) {
      await data.deleteAll(legacyBookKeys);
      await data.flush();
    }
    await catalog.put(_versionKey, _catalogVersion);
    await catalog.delete(_dirtyKey);
    await catalog.flush();
    AppLog.i(
      'chapter-cache',
      'Index rebuilt: books=${_index.length}, '
          'chapters=${_stats(null)['chapterCount']}, '
          'elapsed_ms=${stopwatch.elapsedMilliseconds}',
    );
  }

  Map<String, dynamic> _cleanBook(Map raw) => _stringMap(raw)
    ..remove('cachedChapterIds')
    ..remove('cachedChapterCount')
    ..remove('cachedByteCount')
    ..remove('pinned')
    ..remove('lastAccessedAt');
}

String _chapterKey(String bookId, String chapterId) =>
    'chapter:${jsonEncode([bookId, chapterId])}';

(String, String)? _chapterKeyParts(dynamic key) {
  if (key is! String || !key.startsWith('chapter:')) return null;
  try {
    final parts = jsonDecode(key.substring(8));
    if (parts is List &&
        parts.length == 2 &&
        parts[0] is String &&
        (parts[0] as String).isNotEmpty &&
        parts[1] is String &&
        (parts[1] as String).isNotEmpty) {
      return (parts[0] as String, parts[1] as String);
    }
  } catch (_) {
    return null;
  }
  return null;
}

bool _isChapter(dynamic raw, String bookId, String chapterId) =>
    raw is Map &&
    raw['bookId'] == bookId &&
    raw['chapterId'] == chapterId &&
    raw['text'] is String &&
    (raw['text'] as String).trim().isNotEmpty;

int _accessedAt(dynamic raw) {
  final value = raw is Map ? raw['accessedAt'] : null;
  return value is num && value.isFinite && value >= 0 ? value.toInt() : 0;
}

Map<String, dynamic> _stringMap(Map raw) => {
  for (final entry in raw.entries)
    if (entry.key is String) entry.key as String: entry.value,
};

class _ChapterEntry {
  const _ChapterEntry({
    required this.bookId,
    required this.chapterId,
    required this.title,
    required this.bytes,
    required this.pinned,
    required this.accessedAt,
  });

  final String bookId;
  final String chapterId;
  final String title;
  final int bytes;
  final bool pinned;
  final int accessedAt;

  String get key => _chapterKey(bookId, chapterId);

  _ChapterEntry touch(int time) => _ChapterEntry(
    bookId: bookId,
    chapterId: chapterId,
    title: title,
    bytes: bytes,
    pinned: pinned,
    accessedAt: time,
  );

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'title': title,
    'bytes': bytes,
    'pinned': pinned,
    'accessedAt': accessedAt,
  };

  static _ChapterEntry? fromMap(dynamic raw) {
    if (raw is! Map ||
        raw['bookId'] is! String ||
        (raw['bookId'] as String).isEmpty ||
        raw['chapterId'] is! String ||
        (raw['chapterId'] as String).isEmpty ||
        raw['bytes'] is! int ||
        (raw['bytes'] as int) < 0) {
      return null;
    }
    return _ChapterEntry(
      bookId: raw['bookId'],
      chapterId: raw['chapterId'],
      title: raw['title']?.toString() ?? '',
      bytes: raw['bytes'],
      pinned: raw['pinned'] == true,
      accessedAt: _accessedAt(raw),
    );
  }
}
