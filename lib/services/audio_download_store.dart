import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/chapter_media.dart';
import '../models/media_item.dart';

/// 一章真人讲书/智能朗读音频的离线缓存记录。
///
/// 落盘的是**原始 cenc-aes-ctr 加密字节**（与短剧离线同一姿态）：回放时把
/// `file://` 路径和内容密钥一起交给原生播放器，解密仍发生在 C 核心流层，
/// 磁盘上永远没有明文音频。
///
/// 与短剧一样，keyHex **不进章节记录本身**：它只存在同一个箱里的
/// `key:<itemId>|<toneId>` 条目下，读取时由 [AudioDownloadStore] 拼回
/// [CachedAudioChapter]。
@immutable
class CachedAudioChapter {
  const CachedAudioChapter({
    required this.bookId,
    required this.itemId,
    required this.toneId,
    required this.title,
    required this.index,
    required this.keyHex,
    required this.bytes,
    required this.filePath,
    required this.cachedAt,
    this.durationMs,
  });

  final String bookId;
  final String itemId;

  /// 下载时选定的音色（真人讲书是 `abook_id`，智能朗读是 `tts_tones` 的 id）。
  /// 同一章在不同音色下是**两份**不同的资源，记录与文件都按音色区分。
  final String toneId;
  final String title;
  final int index;

  /// 该流的内容密钥（hex）；明文流为空串。
  final String keyHex;
  final int bytes;
  final String filePath;
  final int cachedAt;
  final int? durationMs;

  /// 章节记录 as persisted：故意不带 keyHex。
  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'itemId': itemId,
    'toneId': toneId,
    'title': title,
    'index': index,
    'bytes': bytes,
    'filePath': filePath,
    'cachedAt': cachedAt,
    if (durationMs != null) 'durationMs': durationMs,
  };

  /// 用记录 + 单独存放的密钥拼回一条缓存章节。[keyHex] 对明文流是 ''。
  static CachedAudioChapter? fromMap(dynamic raw, {String keyHex = ''}) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final itemId = raw['itemId'];
    final toneId = raw['toneId'];
    final filePath = raw['filePath'];
    if (bookId is! String ||
        bookId.isEmpty ||
        itemId is! String ||
        itemId.isEmpty ||
        toneId is! String ||
        toneId.isEmpty ||
        filePath is! String ||
        filePath.isEmpty) {
      return null;
    }
    return CachedAudioChapter(
      bookId: bookId,
      itemId: itemId,
      toneId: toneId,
      title: raw['title']?.toString() ?? '',
      index: raw['index'] is num ? (raw['index'] as num).toInt() : 0,
      keyHex: keyHex,
      bytes: raw['bytes'] is num ? (raw['bytes'] as num).toInt() : 0,
      filePath: filePath,
      cachedAt: raw['cachedAt'] is num ? (raw['cachedAt'] as num).toInt() : 0,
      durationMs: raw['durationMs'] is num
          ? (raw['durationMs'] as num).toInt()
          : null,
    );
  }

  /// 离线回放的取流结果：url 是 `file://` 标记，原生播放器据此走本地文件桥
  /// 并用同一把 key 解密。
  AudioSource toSource() => AudioSource(
    itemId: itemId,
    url: 'file://$filePath',
    toneId: toneId,
    duration: durationMs == null
        ? null
        : Duration(milliseconds: durationMs!),
    keyHex: keyHex,
  );
}

/// 一本书在某个音色下的下载目录（书名/封面/章节表），入队时落库，管理界面
/// 靠它自举，不依赖打开过的页面传元数据。
@immutable
class CachedAudioBook {
  CachedAudioBook({
    required this.bookId,
    required this.title,
    required this.cover,
    required this.toneId,
    required List<Chapter> chapters,
  }) : chapters = List<Chapter>.unmodifiable(chapters);

  final String bookId;
  final String title;
  final String cover;
  final String toneId;
  final List<Chapter> chapters;

  Map<String, dynamic> toMap() => {
    'bookId': bookId,
    'title': title,
    'cover': cover,
    'toneId': toneId,
    'chapters': [
      for (final chapter in chapters)
        {'itemId': chapter.itemId, 'title': chapter.title},
    ],
  };

  static CachedAudioBook? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final bookId = raw['bookId'];
    final toneId = raw['toneId'];
    if (bookId is! String || bookId.isEmpty || toneId is! String) return null;
    final rawChapters = raw['chapters'];
    final chapters = <Chapter>[
      if (rawChapters is List)
        for (final entry in rawChapters)
          if (entry is Map && entry['itemId'] is String)
            Chapter(
              itemId: entry['itemId'] as String,
              title: entry['title']?.toString() ?? '',
              volumeName: '',
            ),
    ];
    return CachedAudioBook(
      bookId: bookId,
      title: raw['title']?.toString() ?? '',
      cover: raw['cover']?.toString() ?? '',
      toneId: toneId,
      chapters: chapters,
    );
  }
}

/// 听书音频的离线缓存。
///
/// 只负责记录与文件归属；下载流程见 `audio_downloader.dart`，离线命中见
/// `audio_playback_controller.dart`。
abstract interface class AudioDownloadStore {
  /// 箱是否就绪。离线命中的读路径先看这个门：Hive 未初始化时触碰
  /// openBox 会产生拦不住的游离异步错误。
  bool get isReady;

  Future<void> warmUp();

  Future<Directory> directory();

  /// 记录一本书的章节表，下载管理界面靠它显示书名与进度。
  Future<void> ensureBook(CachedAudioBook book);

  Future<void> saveChapter(CachedAudioChapter chapter);

  Future<bool> isDownloaded(String itemId, {required String toneId});

  Future<CachedAudioChapter?> chapter(String itemId, {required String toneId});

  /// 某本书在某个音色下已下载的章节 id 集合。
  Future<Set<String>> downloadedIds(String bookId, {required String toneId});

  Future<void> removeChapter(String itemId, {required String toneId});

  Future<void> removeBook(String bookId, {required String toneId});

  Future<int> totalBytes();

  /// 记录变更计数；下载器与界面靠它同步「已下载」状态。
  ValueListenable<int> get changes;
}

/// Hive 实现。箱名 `audio_download_v1`，与短剧箱分开：两者的记录形状、
/// 目录和删除语义都不同，混箱会让迁移和清理互相牵连。
class HiveAudioDownloadStore implements AudioDownloadStore {
  HiveAudioDownloadStore({
    HiveInterface? hive,
    Future<Directory> Function()? directoryResolver,
  }) : _hive = hive ?? Hive,
       _dirResolver = directoryResolver;

  static final HiveAudioDownloadStore instance = HiveAudioDownloadStore();

  static const _boxName = 'audio_download_v1';

  /// 章节记录与内容密钥的键名。密钥单独一条，永不写进章节记录（P1-4 约定）。
  static String _chapterKey(String itemId, String toneId) =>
      'chapter:$itemId|$toneId';
  static String _keyKey(String itemId, String toneId) =>
      'key:$itemId|$toneId';
  static String _bookKey(String bookId, String toneId) =>
      'book:$bookId|$toneId';

  final HiveInterface _hive;
  final Future<Directory> Function()? _dirResolver;
  Directory? _dir;

  @override
  final ValueNotifier<int> changes = ValueNotifier(0);

  Future<Box<dynamic>>? _opening;
  Future<void> _writes = Future<void>.value();

  @override
  bool get isReady => _hive.isBoxOpen(_boxName);

  @override
  Future<void> warmUp() async {
    try {
      await _box();
    } catch (_) {
      // 可选数据：打不开就退化为「本会话不查离线」。
      _opening = null;
    }
  }

  Future<Box<dynamic>> _box() async {
    if (_hive.isBoxOpen(_boxName)) {
      return _hive.box<dynamic>(_boxName);
    }
    final opening = _opening ??= _openBox();
    try {
      return await opening;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  Future<Box<dynamic>> _openBox() => _hive.openBox<dynamic>(_boxName);

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

  @override
  Future<Directory> directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    final root = await (_dirResolver?.call() ?? getApplicationSupportDirectory());
    final dir = Directory('${root.path}${Platform.pathSeparator}offline-audio');
    await dir.create(recursive: true);
    return _dir = dir;
  }

  bool _isChapter(dynamic value) =>
      value is Map &&
      value['bookId'] is String &&
      (value['bookId'] as String).isNotEmpty &&
      value['itemId'] is String &&
      (value['itemId'] as String).isNotEmpty &&
      value['toneId'] is String &&
      (value['toneId'] as String).isNotEmpty &&
      value['filePath'] is String &&
      (value['filePath'] as String).isNotEmpty;

  @override
  Future<void> ensureBook(CachedAudioBook book) => _serialize((box) async {
    if (book.bookId.isEmpty || book.chapters.isEmpty) return;
    final record = book.toMap()
      ..['cachedAt'] = DateTime.now().millisecondsSinceEpoch;
    await box.put(_bookKey(book.bookId, book.toneId), record);
    changes.value++;
  });

  @override
  Future<void> saveChapter(CachedAudioChapter chapter) =>
      _serialize((box) async {
        if (chapter.bookId.isEmpty ||
            chapter.itemId.isEmpty ||
            chapter.toneId.isEmpty) {
          return;
        }
        // 先写密钥：中途崩溃只会留下一条孤立密钥（下次删除/重下覆盖），
        // 不会出现「记录说有 key 但箱里没有」的不可播记录。
        await box.put(
          _keyKey(chapter.itemId, chapter.toneId),
          chapter.keyHex,
        );
        await box.put(
          _chapterKey(chapter.itemId, chapter.toneId),
          chapter.toMap(),
        );
        changes.value++;
      });

  @override
  Future<bool> isDownloaded(String itemId, {required String toneId}) =>
      _serialize((box) async {
        if (itemId.isEmpty || toneId.isEmpty) return false;
        return _isChapter(box.get(_chapterKey(itemId, toneId)));
      });

  @override
  Future<CachedAudioChapter?> chapter(String itemId,
      {required String toneId}) => _serialize((box) async {
    if (itemId.isEmpty || toneId.isEmpty) return null;
    final raw = box.get(_chapterKey(itemId, toneId));
    if (!_isChapter(raw)) return null;
    final keyHex = box.get(_keyKey(itemId, toneId));
    return CachedAudioChapter.fromMap(
      raw,
      keyHex: keyHex is String ? keyHex : '',
    );
  });

  @override
  Future<Set<String>> downloadedIds(String bookId,
      {required String toneId}) => _serialize((box) async {
    if (bookId.isEmpty || toneId.isEmpty) return <String>{};
    return <String>{
      for (final value in box.values)
        if (_isChapter(value) &&
            value['bookId'] == bookId &&
            value['toneId'] == toneId)
          value['itemId'] as String,
    };
  });

  @override
  Future<void> removeChapter(String itemId, {required String toneId}) =>
      _serialize((box) async {
        if (itemId.isEmpty || toneId.isEmpty) return;
        final raw = box.get(_chapterKey(itemId, toneId));
        if (_isChapter(raw)) await _deleteOwnedFile(raw['filePath'] as String);
        await box.deleteAll([
          _chapterKey(itemId, toneId),
          _keyKey(itemId, toneId),
        ]);
        changes.value++;
      });

  @override
  Future<void> removeBook(String bookId, {required String toneId}) =>
      _serialize((box) async {
        if (bookId.isEmpty || toneId.isEmpty) return;
        final doomed = <String>[_bookKey(bookId, toneId)];
        for (final value in box.values) {
          if (!_isChapter(value) ||
              value['bookId'] != bookId ||
              value['toneId'] != toneId) {
            continue;
          }
          doomed
            ..add(_chapterKey(value['itemId'] as String, toneId))
            ..add(_keyKey(value['itemId'] as String, toneId));
          await _deleteOwnedFile(value['filePath'] as String);
        }
        await box.deleteAll(doomed);
        changes.value++;
      });

  @override
  Future<int> totalBytes() => _serialize((box) async {
    var bytes = 0;
    for (final value in box.values) {
      if (!_isChapter(value)) continue;
      final size = value['bytes'];
      if (size is num && size.isFinite && size > 0) bytes += size.toInt();
    }
    return bytes;
  });

  /// 只删属于本箱目录的文件。
  ///
  /// 记录里的路径可以被改箱内容的人指向任意位置，直接 `File(...).delete()`
  /// 就成了任意文件删除（短剧侧 CRIT 同源问题）。路径不在 `offline-audio`
  /// 根内时保留文件、只删记录。
  Future<void> _deleteOwnedFile(String filePath) async {
    try {
      final root = await directory();
      final rootPath = root.absolute.path;
      final file = File(filePath);
      final absolute = file.absolute.path;
      final resolved = await file.resolveSymbolicLinks();
      if (!_within(rootPath, absolute) && !_within(rootPath, resolved)) return;
      await file.delete();
    } on FileSystemException catch (_) {
      // 文件已不存在是删除的常态结果。
    } on ArgumentError catch (_) {
      // 非法路径：记录照样删，文件留给系统清理。
    }
  }

  static bool _within(String root, String candidate) {
    final normalizedRoot = root.replaceAll('\\', '/').toLowerCase();
    final normalized = candidate.replaceAll('\\', '/').toLowerCase();
    return normalized == normalizedRoot ||
        normalized.startsWith('$normalizedRoot/');
  }
}
