import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/media_item.dart';
import 'chapter_cache_worker.dart';
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

/// UI-side cache facade. Hive I/O, migration and encryption stay in one worker;
/// list queries return metadata without opening the chapter-body box.
class ChapterCacheStore implements ChapterCache {
  ChapterCacheStore({
    HiveInterface? hive,
    this._keys,
    this.maxEntries = 500,
    this.maxBytes = 80 * 1024 * 1024,
    this.catalogTtl = const Duration(days: 30),
  }) : _hive = hive ?? Hive;

  static final ChapterCacheStore instance = ChapterCacheStore();

  final HiveInterface _hive;
  final SecureKeyProvider? _keys;
  final int maxEntries;
  final int maxBytes;
  final Duration catalogTtl;
  final ValueNotifier<int> changes = ValueNotifier(0);
  Future<ChapterCacheWorker>? _opening;
  Future<void>? _closing;
  bool _closed = false;
  int _textEncodes = 0;

  @override
  int get chapterCapacity => maxEntries;

  @visibleForTesting
  int get textEncodes => _textEncodes;

  Future<ChapterCacheWorker> _startWorker() async {
    final path = (_hive as dynamic).homePath as String?;
    if (path == null || path.isEmpty) {
      throw StateError('Hive must be initialized before opening the cache');
    }
    final key = await (_keys ?? SecureKeyProvider.instance).getOrCreateKey();
    if (key == null) {
      throw StateError(
        'Encryption key unavailable; chapter cache stays closed',
      );
    }
    return ChapterCacheWorker.start(
      path: path,
      encryptionKey: key,
      maxEntries: maxEntries,
      maxBytes: maxBytes,
      catalogTtl: catalogTtl,
    );
  }

  Future<ChapterCacheWorker> _worker() async {
    if (_closed) throw StateError('Chapter cache is closed');
    final opening = _opening ??= _startWorker();
    try {
      final worker = await opening;
      if (!worker.isClosed) return worker;
      if (identical(_opening, opening)) _opening = null;
      return _worker();
    } catch (_) {
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
  }

  Future<dynamic> _request(
    ChapterCacheCommand command, [
    Map<String, dynamic> args = const {},
  ]) async {
    final worker = await _worker();
    try {
      return await worker.request(command, args);
    } finally {
      _textEncodes = worker.textEncodes;
    }
  }

  @override
  Future<String?> read({
    required String bookId,
    required String chapterId,
  }) async =>
      await _request(ChapterCacheCommand.read, {
            'bookId': bookId,
            'chapterId': chapterId,
          })
          as String?;

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async {
    await _request(ChapterCacheCommand.write, {
      'bookId': bookId,
      'chapterId': chapterId,
      'title': title,
      'text': text,
      'pinned': pinned,
    });
    changes.value++;
  }

  @override
  Future<void> saveBook(CachedBook book) async {
    await _request(ChapterCacheCommand.saveBook, book.toMap());
  }

  @override
  Future<Set<String>> cachedChapterIds(String bookId) async =>
      (await _request(ChapterCacheCommand.cachedChapterIds, {'bookId': bookId})
              as List)
          .cast<String>()
          .toSet();

  Future<ChapterCacheStats> stats({String? bookId}) async =>
      _stats(await _request(ChapterCacheCommand.stats, {'bookId': bookId}));

  ChapterCacheStats _stats(dynamic raw) => ChapterCacheStats(
    chapterCount: raw['chapterCount'] as int,
    byteCount: raw['byteCount'] as int,
  );

  Future<List<CachedBookSummary>> books() async {
    final records = await _request(ChapterCacheCommand.books) as List;
    return [
      for (final record in records)
        if (CachedBook.fromMap(record['book']) case final book?)
          CachedBookSummary(book, _stats(record['stats'])),
    ];
  }

  @override
  Future<CachedBook?> cachedBook(String bookId) async => CachedBook.fromMap(
    await _request(ChapterCacheCommand.cachedBook, {'bookId': bookId}),
  );

  @override
  Future<CachedBook?> savedCatalogue(String bookId) async => CachedBook.fromMap(
    await _request(ChapterCacheCommand.savedCatalogue, {'bookId': bookId}),
  );

  Future<void> clear({String? bookId}) async {
    await _request(ChapterCacheCommand.clear, {'bookId': bookId});
    changes.value++;
  }

  /// Drain queued writes and release the worker's file locks before app exit.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final opening = _opening;
    if (opening == null) return;
    final ChapterCacheWorker worker;
    try {
      worker = await opening;
    } catch (_) {
      return;
    }
    await worker.close();
    _opening = null;
  }
}

String formatCacheBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
  final mib = kib / 1024;
  return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
}
