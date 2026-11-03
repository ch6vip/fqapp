import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/media_item.dart';
import 'chapter_cache_bytes.dart';
import 'encrypted_hive.dart';
import 'secure_key_provider.dart';

abstract interface class ChapterCache {
  Future<String?> read({required String bookId, required String chapterId});

  /// Writes one chapter of [bookId].
  ///
  /// [pinned] marks a chapter the user asked to download: pinned chapters are
  /// never evicted and do not consume the automatic cache's budget, which is
  /// what lets a whole-book download run past [chapterCapacity] intact.
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  });
  Future<void> saveBook(CachedBook book);
  Future<Set<String>> cachedChapterIds(String bookId);

  /// [bookId] 的缓存目录，只在它确实还有缓存章节时返回；目录本身被清掉时用
  /// 缓存章节重建。null 表示这本书没有可离线阅读的正文。
  ///
  /// 书架点书与详情页兜底只关心一本书，用它比 [books] 便宜。
  Future<CachedBook?> cachedBook(String bookId);

  /// [bookId] 保存过的目录，**不要求正文还在**。
  ///
  /// 漫画没有正文缓存（图片带 per-launch 能力值，不能落盘），所以它只能靠
  /// 目录判断能否跳过详情页续读。[cachedBook] 按「有没有可离线正文」回答，
  /// 对漫画恒为 null，因此单独开这个入口。未保存过目录时返回 null。
  Future<CachedBook?> savedCatalogue(String bookId);

  /// Chapters the automatic cache keeps before evicting the least recently read
  /// ones. Chapters written with `pinned: true` are outside this budget.
  int get chapterCapacity;
}

class CachedBook {
  final String id;
  final String title;
  final String cover;
  final List<Chapter> chapters;

  CachedBook({
    required this.id,
    required this.title,
    this.cover = '',
    required List<Chapter> chapters,
  }) : chapters = List.unmodifiable(chapters);

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'cover': cover,
    'chapters': [
      for (final chapter in chapters)
        {
          'itemId': chapter.itemId,
          'title': chapter.title,
          'volumeName': chapter.volumeName,
          // Older catalogues restore an empty version; opening paragraph
          // comments resolves it from the online directory on demand.
          'version': chapter.version,
        },
    ],
  };

  static CachedBook? fromMap(dynamic raw) {
    if (raw is! Map || raw['id'] is! String || raw['chapters'] is! List) {
      return null;
    }
    final chapters = <Chapter>[];
    for (final value in raw['chapters'] as List) {
      if (value is! Map || value['itemId'] is! String) continue;
      final id = value['itemId'] as String;
      if (id.isEmpty) continue;
      chapters.add(
        Chapter(
          itemId: id,
          title: value['title']?.toString() ?? '',
          volumeName: value['volumeName']?.toString() ?? '',
          version: value['version']?.toString() ?? '',
        ),
      );
    }
    if (chapters.isEmpty) return null;
    return CachedBook(
      id: raw['id'] as String,
      title: raw['title']?.toString() ?? '未知书籍',
      cover: raw['cover']?.toString() ?? '',
      chapters: chapters,
    );
  }
}

@immutable
class ChapterCacheStats {
  final int chapterCount;
  final int byteCount;

  const ChapterCacheStats({
    required this.chapterCount,
    required this.byteCount,
  });
}

class CachedBookSummary {
  final CachedBook book;
  final ChapterCacheStats stats;

  const CachedBookSummary(this.book, this.stats);
}

/// Stores chapter text and a small per-book catalogue.
///
/// The catalogue lives in its own small box so the bookshelf and offline-cache
/// page never open the chapter-body box. Opening that body box used to read
/// and decrypt the whole cache (a heavy download can be hundreds of megabytes)
/// and freeze the UI isolate for about a minute. The chapter body box is only
/// opened when the reader actually needs a chapter text; list queries are
/// proportional to the number of books, not the number of chapters.
class ChapterCacheStore implements ChapterCache {
  ChapterCacheStore({
    HiveInterface? hive,
    this._keys,
    this.maxEntries = 500,
    this.maxBytes = 80 * 1024 * 1024,
    this.catalogTtl = const Duration(days: 30),
  }) : _hive = hive ?? Hive;

  static final ChapterCacheStore instance = ChapterCacheStore();
  static const _boxName = 'chapter_cache_v1';
  static const _catalogBoxName = 'chapter_cache_catalog_v1';

  final HiveInterface _hive;

  /// Encryption-key source. Production uses the shared secure-storage
  /// provider; tests inject an in-memory one. Chapter text must never fall
  /// back to a plaintext box, so [_box] opens with `requireEncryption`.
  final SecureKeyProvider? _keys;

  /// Chapters the automatic cache keeps before evicting the least recently read
  /// ones. What the user downloads is pinned and lives outside this budget, so
  /// a whole-book download is never truncated by it.
  final int maxEntries;

  /// The byte budget that goes with [maxEntries]; pinned downloads are outside
  /// it as well.
  final int maxBytes;

  @override
  int get chapterCapacity => maxEntries;

  /// Detached (catalogue-only) records untouched for this long are dropped.
  final Duration catalogTtl;
  final ValueNotifier<int> changes = ValueNotifier(0);

  Future<Box<dynamic>>? _opening;
  Future<Box<dynamic>>? _catalogOpening;
  bool _catalogMigrated = false;
  Future<void> _writes = Future<void>.value();
  final Map<String, int> _accessTimes = {};
  final _byteCounter = ChapterCacheByteCounter();
  int _lastAccessTime = 0;

  /// Number of texts encoded to measure their size, so a regression test can
  /// assert that a reopened cache reuses the persisted measurement instead of
  /// re-encoding every chapter.
  @visibleForTesting
  int get textEncodes => _byteCounter.encodes;

  Future<Box<dynamic>> _box() async {
    // Make sure the catalogue has been migrated before the chapter box is
    // opened. Migration only reads book records from the old box lazily, so it
    // never loads the 200 MB chapter payload into the UI isolate.
    await _catalogBox();
    final box = await (_opening ??= EncryptedHive.openBox<dynamic>(
      _hive,
      _boxName,
      keys: _keys,
      requireEncryption: true,
      compactionStrategy: (entries, deleted) =>
          deleted >= 50 && deleted > entries ~/ 2,
    ));
    if (box.isOpen) return box;
    _opening = null;
    return _box();
  }

  Future<Box<dynamic>> _catalogBox() async {
    final box = await (_catalogOpening ??= EncryptedHive.openBox<dynamic>(
      _hive,
      _catalogBoxName,
      keys: _keys,
      requireEncryption: true,
      compactionStrategy: (entries, deleted) =>
          deleted >= 50 && deleted > entries ~/ 2,
    ));
    if (!box.isOpen) {
      _catalogOpening = null;
      return _catalogBox();
    }
    if (!_catalogMigrated) {
      _catalogMigrated = true;
      try {
        await _migrateLegacyCatalogue(box);
      } catch (_) {
        _catalogMigrated = false;
        rethrow;
      }
    }
    return box;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final operation = _writes.then((_) => action());
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _) {
        _opening = null;
      },
    );
    return operation;
  }

  Future<T> _serialize<T>(Future<T> Function(Box<dynamic>) action) =>
      _enqueue(() async => action(await _box()));

  Future<T> _serializeCatalog<T>(Future<T> Function(Box<dynamic>) action) =>
      _enqueue(() async => action(await _catalogBox()));

  String _key(String bookId, String chapterId) =>
      'chapter:${jsonEncode([bookId, chapterId])}';

  List<String>? _chapterKeyParts(dynamic key) {
    if (key is! String || !key.startsWith('chapter:')) return null;
    try {
      final parts = jsonDecode(key.substring('chapter:'.length));
      if (parts is! List || parts.length < 2) return null;
      final bookId = parts[0];
      final chapterId = parts[1];
      if (bookId is! String || chapterId is! String) return null;
      return [bookId, chapterId];
    } catch (_) {
      return null;
    }
  }

  bool _isChapter(dynamic value) =>
      value is Map &&
      value['bookId'] is String &&
      (value['bookId'] as String).isNotEmpty &&
      value['chapterId'] is String &&
      (value['chapterId'] as String).isNotEmpty &&
      value['text'] is String &&
      (value['text'] as String).trim().isNotEmpty;

  int _bytes(Map entry) => _byteCounter.bytesOf(entry);

  int _accessedAt(Map entry) {
    final value = entry['accessedAt'];
    return value is num && value.isFinite && value >= 0 ? value.toInt() : 0;
  }

  int _touch(String key) {
    final now = DateTime.now().microsecondsSinceEpoch;
    // Several accesses can share a clock tick, especially on Windows.
    _lastAccessTime = now > _lastAccessTime ? now : _lastAccessTime + 1;
    return _accessTimes[key] = _lastAccessTime;
  }

  Map<String, dynamic> _map(dynamic raw) => <String, dynamic>{
    for (final item in (raw as Map).entries)
      if (item.key is String) item.key as String: item.value,
  };

  List<String> _cachedIds(Map record) => [
    for (final id in (record['cachedChapterIds'] as List? ?? const []))
      if (id is String && id.isNotEmpty) id,
  ];

  ChapterCacheStats _statsOf(Map record) => ChapterCacheStats(
    chapterCount: (record['cachedChapterCount'] as num?)?.toInt() ?? 0,
    byteCount: (record['cachedByteCount'] as num?)?.toInt() ?? 0,
  );

  @override
  Future<String?> read({required String bookId, required String chapterId}) =>
      _serialize((box) async {
        final key = _key(bookId, chapterId);
        final raw = await box.get(key);
        if (!_isChapter(raw) ||
            raw['bookId'] != bookId ||
            raw['chapterId'] != chapterId) {
          return null;
        }
        final entry = _map(raw);
        final now = _touch(key);
        final lastSaved = _accessedAt(entry);
        if (now - lastSaved >= const Duration(hours: 1).inMicroseconds) {
          entry['accessedAt'] = now;
          try {
            await box.put(key, entry);
          } catch (_) {
            // Cached text is still readable if an access-time write fails.
          }
        }
        return entry['text'] as String;
      });

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) => _serialize((box) async {
    if (bookId.isEmpty || chapterId.isEmpty || text.trim().isEmpty) return;
    final bytes = utf8.encode(text).length;
    if (bytes > maxBytes) throw StateError('该章节超过缓存容量上限');
    final key = _key(bookId, chapterId);
    final previous = await box.get(key);
    final previousValid = _isChapter(previous);
    final previousBytes = previousValid ? _bytes(previous as Map) : 0;
    final keepPinned = pinned || (previous is Map && _isPinned(previous));
    final accessedAt = _touch(key);
    await box.put(key, {
      'bookId': bookId,
      'chapterId': chapterId,
      'title': title,
      'text': text,
      'bytes': bytes,
      'accessedAt': accessedAt,
      if (keepPinned) 'pinned': true,
    });
    await _updateCatalogueAfterWrite(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      bytes: bytes,
      previousBytes: previousValid ? previousBytes : null,
      pinned: keepPinned,
    );
    // A pinned write does not consume the automatic budget, so it cannot make
    // an unpinned chapter overflow. Skipping trim here avoids scanning a
    // whole-book cache once per downloaded chapter.
    if (!keepPinned) await _trim(box, keepBook: bookId);
    changes.value++;
  });

  @override
  Future<void> saveBook(CachedBook book) => _serializeCatalog((box) async {
    if (book.id.isEmpty || book.chapters.isEmpty) return;
    final record = book.toMap();
    final previous = box.get('book:${book.id}');
    if (previous is Map) {
      for (final field in const [
        'cachedChapterIds',
        'cachedChapterCount',
        'cachedByteCount',
        'pinned',
        'lastAccessedAt',
      ]) {
        if (previous.containsKey(field)) record[field] = previous[field];
      }
    }
    record['cachedAt'] = DateTime.now().millisecondsSinceEpoch;
    record.putIfAbsent('cachedChapterIds', () => <String>[]);
    record.putIfAbsent('cachedChapterCount', () => 0);
    record.putIfAbsent('cachedByteCount', () => 0);
    await box.put('book:${book.id}', record);
    await _sweepCatalogues(box, keepBook: book.id);
  });

  Future<void> _updateCatalogueAfterWrite({
    required String bookId,
    required String chapterId,
    required String title,
    required int bytes,
    required int? previousBytes,
    required bool pinned,
  }) async {
    final box = await _catalogBox();
    final raw = box.get('book:$bookId');
    final record = raw is Map
        ? _map(raw)
        : <String, dynamic>{
            'id': bookId,
            'title': bookId,
            'cover': '',
            'chapters': <dynamic>[],
          };
    final ids = _cachedIds(record).toSet()..add(chapterId);
    record['cachedChapterIds'] = ids.toList();
    record['cachedChapterCount'] = ids.length;
    final oldBytes = (record['cachedByteCount'] as num?)?.toInt() ?? 0;
    record['cachedByteCount'] = oldBytes + bytes - (previousBytes ?? 0);
    record['pinned'] = record['pinned'] == true || pinned;
    record['lastAccessedAt'] = DateTime.now().millisecondsSinceEpoch;
    final chapters = record['chapters'];
    if (chapters is! List || chapters.isEmpty) {
      record['chapters'] = [
        {'itemId': chapterId, 'title': title, 'volumeName': '', 'version': ''},
      ];
    }
    await box.put('book:$bookId', record);
  }

  @override
  Future<Set<String>> cachedChapterIds(String bookId) =>
      _serializeCatalog((box) async {
        await _ensureCatalogueCoverage(box);
        final record = box.get('book:$bookId');
        return record is Map ? _cachedIds(record).toSet() : <String>{};
      });

  Future<ChapterCacheStats> stats({String? bookId}) =>
      _serializeCatalog((box) async {
        await _ensureCatalogueCoverage(box);
        var chapters = 0;
        var bytes = 0;
        for (final key in box.keys) {
          if (key is! String || !key.startsWith('book:')) continue;
          if (bookId != null && key.substring('book:'.length) != bookId) {
            continue;
          }
          final raw = box.get(key);
          if (raw is! Map) continue;
          chapters += (raw['cachedChapterCount'] as num?)?.toInt() ?? 0;
          bytes += (raw['cachedByteCount'] as num?)?.toInt() ?? 0;
        }
        return ChapterCacheStats(chapterCount: chapters, byteCount: bytes);
      });

  Future<List<CachedBookSummary>> books() => _serializeCatalog((box) async {
    await _ensureCatalogueCoverage(box);
    final books = <CachedBookSummary>[];
    for (final key in box.keys) {
      if (key is! String || !key.startsWith('book:')) continue;
      final raw = box.get(key);
      if (raw is! Map) continue;
      final stats = _statsOf(raw);
      if (stats.chapterCount <= 0) continue;
      final book = CachedBook.fromMap(raw);
      if (book == null) continue;
      books.add(CachedBookSummary(book, stats));
    }
    books.sort(
      (a, b) => _bookSortKey(
        box,
        'book:${b.book.id}',
      ).compareTo(_bookSortKey(box, 'book:${a.book.id}')),
    );
    return books;
  });

  int _bookSortKey(Box<dynamic> box, String key) {
    final raw = box.get(key);
    if (raw is! Map) return 0;
    final value = raw['lastAccessedAt'] ?? raw['cachedAt'];
    return value is num && value.isFinite ? value.toInt() : 0;
  }

  @override
  Future<CachedBook?> cachedBook(String bookId) =>
      _serializeCatalog((box) async {
        if (bookId.isEmpty) return null;
        await _ensureCatalogueCoverage(box);
        final raw = box.get('book:$bookId');
        if (raw is! Map || _statsOf(raw).chapterCount <= 0) return null;
        return CachedBook.fromMap(raw);
      });

  @override
  Future<CachedBook?> savedCatalogue(String bookId) =>
      _serializeCatalog((box) async {
        if (bookId.isEmpty) return null;
        return CachedBook.fromMap(box.get('book:$bookId'));
      });

  Future<void> clear({String? bookId}) => _serialize((box) async {
    final catalog = await _catalogBox();
    if (bookId == null) {
      await box.clear();
      await catalog.clear();
      _accessTimes.clear();
    } else {
      await box.deleteAll([
        'book:$bookId',
        for (final key in box.keys)
          if ((_chapterKeyParts(key)?.first ?? '') == bookId) key,
      ]);
      await catalog.delete('book:$bookId');
      _accessTimes.removeWhere((key, _) {
        final parts = _chapterKeyParts(key);
        return key == 'book:$bookId' || (parts != null && parts[0] == bookId);
      });
    }
    await box.compact();
    await catalog.compact();
    changes.value++;
  });

  /// A chapter the user asked to download, as opposed to one the reader cached
  /// on the way past: it is the user's own copy and the LRU pass leaves it be.
  bool _isPinned(Map entry) => entry['pinned'] == true;

  Future<void> _trim(Box<dynamic> box, {required String keepBook}) async {
    final catalog = await _catalogBox();
    final pinnedBooks = <String>{};
    for (final key in catalog.keys) {
      if (key is! String || !key.startsWith('book:')) continue;
      final raw = catalog.get(key);
      if (raw is Map && raw['pinned'] == true) {
        pinnedBooks.add(key.substring('book:'.length));
      }
    }

    final entries =
        <({dynamic key, String bookId, int bytes, num accessedAt})>[];
    var totalBytes = 0;
    for (final key in box.keys) {
      final parts = _chapterKeyParts(key);
      if (parts == null || pinnedBooks.contains(parts[0])) continue;
      final raw = await box.get(key);
      if (!_isChapter(raw)) continue;
      if (_isPinned(raw as Map)) continue;
      final bytes = _bytes(raw);
      totalBytes += bytes;
      entries.add((
        key: key,
        bookId: parts[0],
        bytes: bytes,
        accessedAt: _accessTimes[key] ?? _accessedAt(raw),
      ));
    }
    entries.sort((a, b) => a.accessedAt.compareTo(b.accessedAt));
    final removed =
        <({dynamic key, String bookId, int bytes, num accessedAt})>[];
    var remaining = entries.length;
    for (final entry in entries) {
      if (remaining <= maxEntries && totalBytes <= maxBytes) break;
      removed.add(entry);
      remaining--;
      totalBytes -= entry.bytes;
    }
    if (removed.isNotEmpty) {
      await box.deleteAll([for (final entry in removed) entry.key]);
      for (final entry in removed) {
        _accessTimes.remove(entry.key);
      }
      await _removeFromCatalogue(removed);
    }
    await _sweepCatalogues(await _catalogBox(), keepBook: keepBook);
  }

  Future<void> _removeFromCatalogue(
    List<({dynamic key, String bookId, int bytes, num accessedAt})> removed,
  ) async {
    final box = await _catalogBox();
    final byBook = <String, List<({String chapterId, int bytes})>>{};
    for (final entry in removed) {
      final parts = _chapterKeyParts(entry.key);
      if (parts == null) continue;
      (byBook[parts[0]] ??= []).add((chapterId: parts[1], bytes: entry.bytes));
    }
    for (final item in byBook.entries) {
      final raw = box.get('book:${item.key}');
      if (raw is! Map) continue;
      final record = _map(raw);
      final ids = _cachedIds(record).toSet();
      var removedBytes = 0;
      for (final chapter in item.value) {
        ids.remove(chapter.chapterId);
        removedBytes += chapter.bytes;
      }
      record['cachedChapterIds'] = ids.toList();
      record['cachedChapterCount'] = ids.length;
      record['cachedByteCount'] =
          ((record['cachedByteCount'] as num?)?.toInt() ?? 0) - removedBytes;
      await box.put('book:${item.key}', record);
    }
  }

  /// Drops catalogue records whose book has no cached chapters. A detached
  /// catalogue younger than [catalogTtl] may belong to a download still in
  /// progress, so it is kept; the rest age out, and the survivors are capped at
  /// [maxEntries] so browsing books online cannot grow Hive without bound.
  Future<void> _sweepCatalogues(Box<dynamic> box, {String? keepBook}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ttl = catalogTtl.inMilliseconds;
    final detached = <({dynamic key, int cachedAt})>[];
    for (final key in box.keys) {
      if (key is! String || !key.startsWith('book:')) continue;
      final raw = box.get(key);
      if (raw is Map &&
          ((raw['cachedChapterCount'] as num?)?.toInt() ?? 0) > 0) {
        continue;
      }
      detached.add((
        key: key,
        cachedAt:
            raw is Map &&
                raw['cachedAt'] is num &&
                (raw['cachedAt'] as num).isFinite
            ? (raw['cachedAt'] as num).toInt()
            : 0,
      ));
    }
    if (detached.isEmpty) return;
    detached.sort((a, b) => a.cachedAt.compareTo(b.cachedAt));
    final keepKey = keepBook == null ? null : 'book:$keepBook';
    final doomed = <dynamic>{};
    var living = detached.length;
    for (final entry in detached) {
      if (entry.key != keepKey && now - entry.cachedAt >= ttl) {
        doomed.add(entry.key);
        living--;
      }
    }
    for (final entry in detached) {
      if (living <= maxEntries) break;
      if (entry.key == keepKey || doomed.contains(entry.key)) continue;
      doomed.add(entry.key);
      living--;
    }
    if (doomed.isEmpty) return;
    await box.deleteAll(doomed);
  }

  /// Reconciles debris left by old versions or by tests that write the
  /// chapter box directly. Production writes keep the catalogue exact; this
  /// pass only runs when the chapter box is already open (so it can never be
  /// the thing that opens a 200 MB box on the UI isolate).
  Future<void> _ensureCatalogueCoverage(Box<dynamic> catalog) async {
    final encName = EncryptedHive.encryptedBoxName(_boxName);
    Box<dynamic>? data;
    if (_hive.isBoxOpen(encName)) {
      data = _hive.box<dynamic>(encName);
    } else if (_hive.isBoxOpen(_boxName)) {
      data = _hive.box<dynamic>(_boxName);
    }
    if (data == null) return;

    var catalogCount = 0;
    for (final key in catalog.keys) {
      if (key is! String || !key.startsWith('book:')) continue;
      final raw = catalog.get(key);
      if (raw is Map) {
        catalogCount += (raw['cachedChapterCount'] as num?)?.toInt() ?? 0;
      }
    }
    var dataCount = 0;
    for (final key in data.keys) {
      if (_chapterKeyParts(key) != null) dataCount++;
    }
    if (catalogCount == dataCount) return;
    await _rebuildCatalogueFromData(catalog, data);
  }

  Future<void> _rebuildCatalogueFromData(
    Box<dynamic> catalog,
    Box<dynamic> data,
  ) async {
    final records = <String, Map<String, dynamic>>{};
    for (final key in catalog.keys) {
      if (key is! String || !key.startsWith('book:')) continue;
      final raw = catalog.get(key);
      if (raw is Map) records[key] = _map(raw);
    }

    final counts = <String, int>{};
    final bytes = <String, int>{};
    final pinned = <String>{};
    final chapters = <String, List<Map<String, dynamic>>>{};
    for (final key in data.keys) {
      final parts = _chapterKeyParts(key);
      if (parts == null) continue;
      final raw = data.get(key);
      if (!_isChapter(raw)) continue;
      final bookId = parts[0];
      counts[bookId] = (counts[bookId] ?? 0) + 1;
      bytes[bookId] = (bytes[bookId] ?? 0) + _bytes(raw as Map);
      if (_isPinned(raw)) pinned.add(bookId);
      (chapters[bookId] ??= <Map<String, dynamic>>[]).add({
        'itemId': parts[1],
        'title': raw['title']?.toString() ?? '',
        'volumeName': '',
        'version': '',
      });
    }

    for (final item in counts.entries) {
      final key = 'book:${item.key}';
      final record =
          records[key] ??
          <String, dynamic>{
            'id': item.key,
            'title': item.key,
            'cover': '',
            'chapters': <dynamic>[],
            'cachedAt': DateTime.now().millisecondsSinceEpoch,
          };
      record['cachedChapterIds'] = [
        for (final chapter in chapters[item.key] ?? const []) chapter['itemId'],
      ];
      record['cachedChapterCount'] = item.value;
      record['cachedByteCount'] = bytes[item.key] ?? 0;
      if (pinned.contains(item.key)) record['pinned'] = true;
      if (record['chapters'] is! List || (record['chapters'] as List).isEmpty) {
        record['chapters'] = chapters[item.key] ?? <Map<String, dynamic>>[];
      }
      records[key] = record;
    }
    if (records.isNotEmpty) await catalog.putAll(records);
  }

  /// Copies old `book:` records from the monolithic v1 box into the new
  /// catalogue box. The old box is opened lazily, so only the small book
  /// records are decrypted here; chapter values are read to compute the
  /// per-book byte totals and are never kept in memory after the pass.
  Future<void> _migrateLegacyCatalogue(Box<dynamic> catalog) async {
    final encName = EncryptedHive.encryptedBoxName(_boxName);
    final exists =
        await _hive.boxExists(encName) || await _hive.boxExists(_boxName);
    if (!exists) return;
    if (catalog.isNotEmpty) return;

    final old = await EncryptedHive.openLazyBox<dynamic>(
      _hive,
      _boxName,
      keys: _keys,
      requireEncryption: true,
    );
    try {
      final keys = old.keys.toList();
      final bookKeys = <String>[];
      final chapterKeys = <dynamic>[];
      for (final key in keys) {
        if (key is! String) continue;
        if (key.startsWith('book:')) {
          bookKeys.add(key);
        } else if (key.startsWith('chapter:')) {
          chapterKeys.add(key);
        }
      }

      final counts = <String, int>{};
      final bytes = <String, int>{};
      final pinned = <String>{};
      final chapters = <String, List<Map<String, dynamic>>>{};
      for (final key in chapterKeys) {
        final parts = _chapterKeyParts(key);
        final raw = await old.get(key);
        if (parts == null || !_isChapter(raw)) continue;
        final bookId = parts[0];
        counts[bookId] = (counts[bookId] ?? 0) + 1;
        bytes[bookId] = (bytes[bookId] ?? 0) + _bytes(raw as Map);
        if (_isPinned(raw)) pinned.add(bookId);
        (chapters[bookId] ??= <Map<String, dynamic>>[]).add({
          'itemId': parts[1],
          'title': raw['title']?.toString() ?? '',
          'volumeName': '',
          'version': '',
        });
      }

      final records = <String, dynamic>{};
      for (final key in bookKeys) {
        final raw = await old.get(key);
        if (raw is! Map) continue;
        final bookId = key.substring('book:'.length);
        final record = _map(raw);
        record['cachedChapterIds'] = [
          for (final chapter in chapters[bookId] ?? const []) chapter['itemId'],
        ];
        record['cachedChapterCount'] = counts[bookId] ?? 0;
        record['cachedByteCount'] = bytes[bookId] ?? 0;
        if (pinned.contains(bookId)) record['pinned'] = true;
        if (record['chapters'] is! List ||
            (record['chapters'] as List).isEmpty) {
          record['chapters'] = chapters[bookId] ?? <Map<String, dynamic>>[];
        }
        records[key] = record;
      }
      for (final item in chapters.entries) {
        final key = 'book:${item.key}';
        if (records.containsKey(key)) continue;
        records[key] = {
          'id': item.key,
          'title': item.key,
          'cover': '',
          'chapters': item.value,
          'cachedChapterIds': [
            for (final chapter in item.value) chapter['itemId'],
          ],
          'cachedChapterCount': counts[item.key] ?? 0,
          'cachedByteCount': bytes[item.key] ?? 0,
          'cachedAt': DateTime.now().millisecondsSinceEpoch,
        };
      }
      if (records.isNotEmpty) await catalog.putAll(records);
    } finally {
      await old.close();
    }
  }
}

String formatCacheBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
  final mib = kib / 1024;
  return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
}
