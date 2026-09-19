import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/media_item.dart';

abstract interface class ChapterCache {
  Future<String?> read({required String bookId, required String chapterId});
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
  });
  Future<void> saveBook(CachedBook book);
  Future<Set<String>> cachedChapterIds(String bookId);
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

class ChapterCacheStore implements ChapterCache {
  ChapterCacheStore({
    HiveInterface? hive,
    this.maxEntries = 500,
    this.maxBytes = 80 * 1024 * 1024,
    this.catalogTtl = const Duration(days: 30),
  }) : _hive = hive ?? Hive;

  static final ChapterCacheStore instance = ChapterCacheStore();
  static const _boxName = 'chapter_cache_v1';

  final HiveInterface _hive;
  final int maxEntries;
  final int maxBytes;

  /// Detached (catalogue-only) records untouched for this long are dropped.
  final Duration catalogTtl;
  final ValueNotifier<int> changes = ValueNotifier(0);
  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();
  final Map<String, int> _accessTimes = {};
  final Expando<int> _byteCounts = Expando<int>();
  int _lastAccessTime = 0;

  Future<Box<dynamic>> _box() async {
    final box = await (_opening ??= _hive.openBox<dynamic>(
      _boxName,
      compactionStrategy: (entries, deleted) =>
          deleted >= 50 && deleted > entries ~/ 2,
    ));
    if (box.isOpen) return box;
    _opening = null;
    return _box();
  }

  Future<T> _serialize<T>(Future<T> Function(Box<dynamic>) action) {
    final operation = _writes.then((_) async => action(await _box()));
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _) {
        _opening = null;
      },
    );
    return operation;
  }

  String _key(String bookId, String chapterId) =>
      'chapter:${jsonEncode([bookId, chapterId])}';

  bool _isChapter(dynamic value) =>
      value is Map &&
      value['bookId'] is String &&
      (value['bookId'] as String).isNotEmpty &&
      value['chapterId'] is String &&
      (value['chapterId'] as String).isNotEmpty &&
      value['text'] is String &&
      (value['text'] as String).trim().isNotEmpty;

  int _bytes(Map entry) {
    // Re-measure even when a stored 'bytes' field claims otherwise: damaged
    // or hostile metadata must not under-report its way past the capacity
    // caps (chapter_cache_store_test locks this). The post-restart trim cost
    // of re-encoding is the deliberate price of that validation.
    return _byteCounts[entry] ??= utf8.encode(entry['text'] as String).length;
  }

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

  @override
  Future<String?> read({required String bookId, required String chapterId}) =>
      _serialize((box) async {
        final key = _key(bookId, chapterId);
        final raw = box.get(key);
        if (!_isChapter(raw) ||
            raw['bookId'] != bookId ||
            raw['chapterId'] != chapterId) {
          return null;
        }
        final entry = <String, dynamic>{
          for (final item in (raw as Map).entries)
            if (item.key is String) item.key as String: item.value,
        };
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
  }) => _serialize((box) async {
    if (bookId.isEmpty || chapterId.isEmpty || text.trim().isEmpty) return;
    final bytes = utf8.encode(text).length;
    if (bytes > maxBytes) throw StateError('该章节超过缓存容量上限');
    final key = _key(bookId, chapterId);
    final accessedAt = _touch(key);
    await box.put(key, {
      'bookId': bookId,
      'chapterId': chapterId,
      'title': title,
      'text': text,
      'bytes': bytes,
      'accessedAt': accessedAt,
    });
    await _trim(box, keepBook: bookId);
    changes.value++;
  });

  @override
  Future<void> saveBook(CachedBook book) => _serialize((box) async {
    if (book.id.isEmpty || book.chapters.isEmpty) return;
    final record = book.toMap();
    record['cachedAt'] = DateTime.now().millisecondsSinceEpoch;
    await box.put('book:${book.id}', record);
    await _sweepCatalogues(box, keepBook: book.id);
  });

  @override
  Future<Set<String>> cachedChapterIds(String bookId) =>
      _serialize((box) async {
        return {
          for (final value in box.values)
            if (_isChapter(value) && value['bookId'] == bookId)
              value['chapterId'] as String,
        };
      });

  Future<ChapterCacheStats> stats({String? bookId}) => _serialize((box) async {
    var bytes = 0;
    var chapters = 0;
    for (final value in box.values) {
      if (!_isChapter(value) || (bookId != null && value['bookId'] != bookId)) {
        continue;
      }
      chapters++;
      bytes += _bytes(value as Map);
    }
    return ChapterCacheStats(chapterCount: chapters, byteCount: bytes);
  });

  Future<List<CachedBookSummary>> books() => _serialize((box) async {
    final counts = <String, int>{};
    final bytes = <String, int>{};
    final accessed = <String, num>{};
    final chaptersByBook = <String, List<Chapter>>{};
    for (final value in box.values) {
      if (!_isChapter(value)) continue;
      final id = value['bookId'] as String;
      counts[id] = (counts[id] ?? 0) + 1;
      bytes[id] = (bytes[id] ?? 0) + _bytes(value as Map);
      final time = _accessedAt(value);
      if (time > (accessed[id] ?? 0)) accessed[id] = time;
      (chaptersByBook[id] ??= <Chapter>[]).add(
        Chapter(
          itemId: value['chapterId'] as String,
          title: value['title']?.toString() ?? '',
          volumeName: '',
        ),
      );
    }
    final books = <CachedBookSummary>[];
    for (final id in counts.keys) {
      // A batch's catalogue can be evicted while later chapters for the same
      // book still land; rebuild the summary from those chapters so the
      // offline entry stays discoverable instead of orphaning them.
      final book =
          CachedBook.fromMap(box.get('book:$id')) ??
          CachedBook(id: id, title: id, chapters: chaptersByBook[id]!);
      books.add(
        CachedBookSummary(
          book,
          ChapterCacheStats(chapterCount: counts[id]!, byteCount: bytes[id]!),
        ),
      );
    }
    books.sort(
      (a, b) => (accessed[b.book.id] ?? 0).compareTo(accessed[a.book.id] ?? 0),
    );
    return books;
  });

  Future<void> clear({String? bookId}) => _serialize((box) async {
    if (bookId == null) {
      await box.clear();
      _accessTimes.clear();
    } else {
      await box.deleteAll([
        'book:$bookId',
        for (final key in box.keys)
          if (key is String &&
              key.startsWith('chapter:[${jsonEncode(bookId)},'))
            key,
      ]);
      _accessTimes.removeWhere((key, _) => !box.containsKey(key));
    }
    await box.compact();
    changes.value++;
  });

  Future<void> _trim(Box<dynamic> box, {required String keepBook}) async {
    final entries = <({dynamic key, int bytes, num accessedAt})>[];
    var totalBytes = 0;
    for (final key in box.keys) {
      final raw = box.get(key);
      if (!_isChapter(raw)) continue;
      final bytes = _bytes(raw as Map);
      totalBytes += bytes;
      entries.add((
        key: key,
        bytes: bytes,
        accessedAt: _accessTimes[key] ?? _accessedAt(raw),
      ));
    }
    entries.sort((a, b) => a.accessedAt.compareTo(b.accessedAt));
    final removed = <dynamic>[];
    var remaining = entries.length;
    for (final entry in entries) {
      if (remaining <= maxEntries && totalBytes <= maxBytes) break;
      removed.add(entry.key);
      remaining--;
      totalBytes -= entry.bytes;
    }
    if (removed.isNotEmpty) {
      await box.deleteAll(removed);
      for (final key in removed) {
        _accessTimes.remove(key);
      }
    }
    // Catalogue records are not chapters, so a trim pass never removes one
    // just because it evicted a chapter: the catalogue is written before the
    // first chapter of a batch lands, and a later chapter for the same book
    // would otherwise be orphaned from the offline entry.
    await _sweepCatalogues(box, keepBook: keepBook);
  }

  /// Drops catalogue records whose book has no cached chapters. A detached
  /// catalogue younger than [catalogTtl] may belong to a download still in
  /// progress, so it is kept; the rest age out, and the survivors are capped at
  /// [maxEntries] so browsing books online cannot grow Hive without bound.
  Future<void> _sweepCatalogues(Box<dynamic> box, {String? keepBook}) async {
    final liveBooks = <String>{
      for (final value in box.values)
        if (_isChapter(value)) value['bookId'] as String,
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    final ttl = catalogTtl.inMilliseconds;
    final detached = <({dynamic key, int cachedAt})>[];
    for (final key in box.keys) {
      if (key is! String || !key.startsWith('book:')) continue;
      if (liveBooks.contains(key.substring(5))) continue;
      final raw = box.get(key);
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
}

String formatCacheBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
  final mib = kib / 1024;
  return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
}
