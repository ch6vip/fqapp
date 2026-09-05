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
  }) : _hive = hive ?? Hive;

  static final ChapterCacheStore instance = ChapterCacheStore();
  static const _boxName = 'chapter_cache_v1';

  final HiveInterface _hive;
  final int maxEntries;
  final int maxBytes;
  final ValueNotifier<int> changes = ValueNotifier(0);
  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();
  final Map<String, int> _accessTimes = {};

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
      value['chapterId'] is String &&
      value['text'] is String &&
      (value['text'] as String).trim().isNotEmpty;

  int _bytes(Map entry) =>
      (entry['bytes'] as num?)?.toInt() ??
      utf8.encode(entry['text'] as String).length;

  @override
  Future<String?> read({required String bookId, required String chapterId}) =>
      _serialize((box) async {
        final key = _key(bookId, chapterId);
        final raw = box.get(key);
        if (!_isChapter(raw)) return null;
        final entry = Map<String, dynamic>.from(raw as Map);
        final now = DateTime.now().microsecondsSinceEpoch;
        _accessTimes[key] = now;
        final lastSaved = (entry['accessedAt'] as num?)?.toInt() ?? 0;
        if (now - lastSaved >= const Duration(hours: 1).inMicroseconds) {
          entry['accessedAt'] = now;
          await box.put(key, entry);
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
    _accessTimes[_key(bookId, chapterId)] =
        DateTime.now().microsecondsSinceEpoch;
    await box.put(_key(bookId, chapterId), {
      'bookId': bookId,
      'chapterId': chapterId,
      'title': title,
      'text': text,
      'bytes': bytes,
      'accessedAt': DateTime.now().microsecondsSinceEpoch,
    });
    await _trim(box, keepBook: bookId);
    changes.value++;
  });

  @override
  Future<void> saveBook(CachedBook book) => _serialize((box) async {
    if (book.id.isEmpty || book.chapters.isEmpty) return;
    await box.put('book:${book.id}', book.toMap());
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
    for (final value in box.values) {
      if (!_isChapter(value)) continue;
      final id = value['bookId'] as String;
      counts[id] = (counts[id] ?? 0) + 1;
      bytes[id] = (bytes[id] ?? 0) + _bytes(value as Map);
      final time = value['accessedAt'] as num? ?? 0;
      if (time > (accessed[id] ?? 0)) accessed[id] = time;
    }
    final books = <CachedBookSummary>[];
    for (final id in counts.keys) {
      final book = CachedBook.fromMap(box.get('book:$id'));
      if (book != null) {
        books.add(
          CachedBookSummary(
            book,
            ChapterCacheStats(chapterCount: counts[id]!, byteCount: bytes[id]!),
          ),
        );
      }
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
          if (_isChapter(box.get(key)) && box.get(key)['bookId'] == bookId) key,
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
        accessedAt: _accessTimes[key] ?? raw['accessedAt'] as num? ?? 0,
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
    if (removed.isEmpty) return;
    await box.deleteAll(removed);
    for (final key in removed) {
      _accessTimes.remove(key);
    }
    final retainedBooks = <String>{
      keepBook,
      for (final value in box.values)
        if (_isChapter(value)) value['bookId'] as String,
    };
    await box.deleteAll([
      for (final key in box.keys)
        if (key is String &&
            key.startsWith('book:') &&
            !retainedBooks.contains(key.substring(5)))
          key,
    ]);
  }
}

String formatCacheBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
  final mib = kib / 1024;
  return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
}
