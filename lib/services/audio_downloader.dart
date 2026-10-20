import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/chapter_media.dart';
import '../models/media_item.dart';
import 'api_client.dart';
import 'audio_download_store.dart';

enum AudioDownloadStatus { waiting, downloading, paused, completed, failed }

/// 一个听书音频下载任务的不可变快照：弹层与管理界面都按它渲染。
@immutable
class AudioDownloadTask {
  const AudioDownloadTask({
    required this.bookId,
    required this.itemId,
    required this.toneId,
    required this.title,
    required this.index,
    required this.status,
    this.received = 0,
    this.total,
    this.error,
  });

  final String bookId;
  final String itemId;
  final String toneId;
  final String title;
  final int index;
  final AudioDownloadStatus status;
  final int received;
  final int? total;
  final String? error;

  double? get progress {
    final size = total;
    if (size == null || size <= 0) return null;
    return (received / size).clamp(0.0, 1.0);
  }

  AudioDownloadTask copyWith({
    AudioDownloadStatus? status,
    int? received,
    int? total,
    String? error,
    bool clearError = false,
    bool clearTotal = false,
  }) => AudioDownloadTask(
    bookId: bookId,
    itemId: itemId,
    toneId: toneId,
    title: title,
    index: index,
    status: status ?? this.status,
    received: received ?? this.received,
    total: clearTotal ? null : (total ?? this.total),
    error: clearError ? null : (error ?? this.error),
  );
}

/// 听书音频离线下载引擎。
///
/// 形态与短剧 [DramaDownloader] 一致 —— 按「章」建任务、[concurrency] 并发、
/// `.part` + Range 续传、直链过期重取一次、断网暂停 —— 但换了三处：
///
///  * 取流走 [ApiClient.audioSource]（音色是 URL 的一部分，同一章不同音色是
///    两份独立资源）；
///  * 文件按 `<itemId>__<toneId>.m4a` 命名，因此记录也按音色区分；
///  * 落盘的同样是**原始加密字节**，keyHex 只登记进加密箱，磁盘永无明文。
///
/// 不直接复用 [DramaDownloader] 的原因：两者的取流模型（EpisodeSource 多变体
/// vs 单条 cenc 音源）、文件归属（整剧目录 vs 按音色的章）和记录形状都不同，
/// 强行合并会把短剧那套剧集/画质语义带进听书。共用的只有落盘约定。
class AudioDownloader extends ValueNotifier<List<AudioDownloadTask>> {
  AudioDownloader({
    AudioDownloadStore? store,
    Future<AudioSource> Function(String bookId, String itemId, String toneId)?
    resolve,
    HttpClient Function()? clientFactory,
    this.concurrency = 2,
  }) : _store = store ?? HiveAudioDownloadStore.instance,
       _resolve = resolve ?? _defaultResolve,
       _clientFactory = clientFactory ?? HttpClient.new,
       super(const []) {
    // 管理界面删了记录后，引擎里那条 completed 旧任务必须一起忘掉，
    // 否则 enqueue 会把该章当「已下载」跳过，用户点重新下载毫无反应。
    _store.changes.addListener(_onStoreChanged);
  }

  static final AudioDownloader instance = AudioDownloader();

  /// 文件名里允许出现的字符。章 id 与音色 id 都来自上游，直接拼进路径前
  /// 必须先过这道门（与短剧的 `_safeItemId` 同一约定）。
  static final RegExp _safeToken = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  static bool _isSafe(String value) => _safeToken.hasMatch(value);

  final AudioDownloadStore _store;
  final Future<AudioSource> Function(String bookId, String itemId, String toneId)
  _resolve;
  final HttpClient Function() _clientFactory;
  final int concurrency;

  final Map<String, _MutableTask> _tasks = {};
  final Map<String, _MutableTask> _active = {};
  bool _pumping = false;

  static Future<AudioSource> _defaultResolve(
    String bookId,
    String itemId,
    String toneId,
  ) => ApiClient.instance.audioSource(
    itemId,
    bookId: bookId,
    toneId: toneId,
  );

  static String taskId(String itemId, String toneId) => '$itemId|$toneId';

  /// 官方 onNetChangeCheck 的等价：断网或只剩移动网络时暂停队列，半成品
  /// 保留，恢复由用户在下载面板里点继续。
  void updateConnectivity({required bool online, bool metered = false}) {
    if (online && !metered) return;
    pauseAll(reason: online ? null : '网络已断开，下载已暂停');
  }

  /// 入队若干章。已在队列或已下载的章自动跳过。
  Future<void> enqueue({
    required CachedAudioBook book,
    required List<Chapter> chapters,
  }) async {
    if (chapters.isEmpty) return;
    for (final chapter in chapters) {
      if (!_isSafe(chapter.itemId)) {
        throw ArgumentError.value(
          chapter.itemId,
          'chapter.itemId',
          'must contain only ASCII letters, digits, _ or - (max 128 chars)',
        );
      }
    }
    if (!_isSafe(book.toneId)) {
      throw ArgumentError.value(
        book.toneId,
        'toneId',
        'must contain only ASCII letters, digits, _ or - (max 128 chars)',
      );
    }
    await _store.ensureBook(book);
    var added = false;
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      final id = taskId(chapter.itemId, book.toneId);
      final existing = _tasks[id];
      if (existing != null) {
        // 失败/暂停的任务再点一次等于重试；其余状态不重复入队。
        if (existing.snapshot.status == AudioDownloadStatus.failed ||
            existing.snapshot.status == AudioDownloadStatus.paused) {
          _resumeTask(existing);
          added = true;
        }
        continue;
      }
      if (await _store.isDownloaded(chapter.itemId, toneId: book.toneId)) {
        continue;
      }
      _tasks[id] = _MutableTask(
        AudioDownloadTask(
          bookId: book.bookId,
          itemId: chapter.itemId,
          toneId: book.toneId,
          title: chapter.title,
          index: i,
          status: AudioDownloadStatus.waiting,
        ),
      );
      added = true;
    }
    if (!added) return;
    _publish();
    unawaited(_pump());
  }

  void pause(String itemId, {String toneId = ''}) =>
      _pauseTask(_tasks[_keyOf(itemId, toneId)], reason: '已暂停');

  void pauseAll({String? reason}) {
    var changed = false;
    for (final task in _tasks.values) {
      if (task.snapshot.status == AudioDownloadStatus.waiting ||
          task.snapshot.status == AudioDownloadStatus.downloading) {
        if (task.snapshot.status == AudioDownloadStatus.downloading) {
          task.abort('paused');
        }
        task.snapshot = task.snapshot.copyWith(
          status: AudioDownloadStatus.paused,
          error: reason,
        );
        changed = true;
      }
    }
    if (changed) _publish();
    unawaited(_pump());
  }

  void resume(String itemId, {String toneId = ''}) {
    final task = _tasks[_keyOf(itemId, toneId)];
    if (task == null) return;
    if (task.snapshot.status == AudioDownloadStatus.paused ||
        task.snapshot.status == AudioDownloadStatus.failed) {
      _resumeTask(task);
      _publish();
      unawaited(_pump());
    }
  }

  void resumeAll() {
    for (final task in _tasks.values) {
      if (task.snapshot.status == AudioDownloadStatus.paused ||
          task.snapshot.status == AudioDownloadStatus.failed) {
        _resumeTask(task);
      }
    }
    _publish();
    unawaited(_pump());
  }

  /// 放弃未完成任务并清掉半成品；已完成的删除走 store。
  Future<void> discard(String itemId, {String toneId = ''}) async {
    if (!_isSafe(itemId) || !_isSafe(toneId)) return;
    final task = _tasks.remove(taskId(itemId, toneId));
    task?.abort('discarded');
    _active.remove(taskId(itemId, toneId));
    try {
      final dir = await _store.directory();
      await File(
        '${dir.path}${Platform.pathSeparator}${_fileName(itemId, toneId)}.part',
      ).delete();
    } on FileSystemException catch (_) {
    } on ArgumentError catch (_) {}
    _publish();
    unawaited(_pump());
  }

  /// 清掉不在本队列里的「等待中」任务（例如用户关掉了整本书的下载入口）。
  void clearFinished() {
    final before = _tasks.length;
    _tasks.removeWhere(
      (_, task) =>
          task.snapshot.status == AudioDownloadStatus.completed ||
          task.snapshot.status == AudioDownloadStatus.failed,
    );
    if (_tasks.length != before) _publish();
  }

  String _keyOf(String itemId, String toneId) {
    if (toneId.isNotEmpty) return taskId(itemId, toneId);
    // 未指定音色时按章 id 找第一个任务（单章操作的老调用形态）。
    for (final key in _tasks.keys) {
      if (key.startsWith('$itemId|')) return key;
    }
    return taskId(itemId, '');
  }

  void _pauseTask(_MutableTask? task, {String? reason}) {
    if (task == null) return;
    if (task.snapshot.status != AudioDownloadStatus.waiting &&
        task.snapshot.status != AudioDownloadStatus.downloading) {
      return;
    }
    if (task.snapshot.status == AudioDownloadStatus.downloading) {
      task.abort('paused');
    }
    task.snapshot = task.snapshot.copyWith(
      status: AudioDownloadStatus.paused,
      error: reason,
    );
    _publish();
    unawaited(_pump());
  }

  void _resumeTask(_MutableTask task) {
    task.generation++;
    task.abortReason = null;
    task.snapshot = task.snapshot.copyWith(
      status: AudioDownloadStatus.waiting,
      clearError: true,
    );
  }

  void _onStoreChanged() {
    unawaited(_forgetRemovedDownloads());
  }

  Future<void> _forgetRemovedDownloads() async {
    try {
      final completed = [
        for (final entry in _tasks.entries)
          if (entry.value.snapshot.status == AudioDownloadStatus.completed)
            entry.key,
      ];
      if (completed.isEmpty) return;
      var changed = false;
      for (final key in completed) {
        final task = _tasks[key];
        if (task == null) continue;
        final stillThere = await _store.isDownloaded(
          task.snapshot.itemId,
          toneId: task.snapshot.toneId,
        );
        if (stillThere) continue;
        _tasks.remove(key);
        _active.remove(key);
        changed = true;
      }
      if (changed) _publish();
    } catch (_) {
      // store 不可用：任务留着，下一次变更再清。
    }
  }

  void _publish() {
    value = [for (final task in _tasks.values) task.snapshot];
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_active.length < concurrency) {
        _MutableTask? next;
        for (final entry in _tasks.entries) {
          final task = entry.value;
          if (task.snapshot.status != AudioDownloadStatus.waiting) continue;
          // 上一轮还在收尾时不允许为同一个任务再起一轮：两个循环会写同一个
          // `.part`。
          if (_active.containsKey(entry.key)) continue;
          if (next == null || task.snapshot.index < next.snapshot.index) {
            next = task;
          }
        }
        if (next == null) return;
        final running = next;
        final key = taskId(running.snapshot.itemId, running.snapshot.toneId);
        running.snapshot = running.snapshot.copyWith(
          status: AudioDownloadStatus.downloading,
        );
        _active[key] = running;
        _publish();
        unawaited(_run(key, running));
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(String key, _MutableTask task) async {
    final generation = task.generation;
    var refreshed = false;
    try {
      while (true) {
        final reason = await _runOnce(task);
        if (reason == null) break;
        if (task.abortReason != null) break;
        // CDN 直链会过期（403/410）：重取一次地址再续。
        if (reason == 'stale-url' && !refreshed) {
          refreshed = true;
          continue;
        }
        if (task.snapshot.status == AudioDownloadStatus.downloading) {
          task.snapshot = task.snapshot.copyWith(
            status: AudioDownloadStatus.failed,
            error: reason,
          );
        }
        break;
      }
    } finally {
      _active.remove(key);
    }
    if (task.generation != generation) {
      // 收尾期间用户点了继续：这条状态属于新一轮，别覆盖它。
      _publish();
      unawaited(_pump());
      return;
    }
    final abortReason = task.abortReason;
    task.abortReason = null;
    if (abortReason == 'paused' &&
        task.snapshot.status == AudioDownloadStatus.downloading) {
      task.snapshot = task.snapshot.copyWith(
        status: AudioDownloadStatus.paused,
      );
    } else if (abortReason == 'discarded') {
      _tasks.remove(key);
    }
    _publish();
    unawaited(_pump());
  }

  /// 跑一次下载（每次都重新 resolve 取流地址）。返回 null 表示终态（完成或
  /// 用户暂停/放弃）、`stale-url` 表示直链失效可重取、其他值是失败原因。
  Future<String?> _runOnce(_MutableTask task) async {
    HttpClient? client;
    RandomAccessFile? sink;
    try {
      final itemId = task.snapshot.itemId;
      final toneId = task.snapshot.toneId;
      if (!_isSafe(itemId) || !_isSafe(toneId)) return '无效的章节或音色';
      final dir = await _store.directory();
      final finalPath =
          '${dir.path}${Platform.pathSeparator}${_fileName(itemId, toneId)}';
      final partFile = File('$finalPath.part');
      var received = await partFile.exists() ? await partFile.length() : 0;

      final source = await _resolve(task.snapshot.bookId, itemId, toneId);
      if (task.abortReason != null) return null;
      if (source.itemId != itemId) return '取流结果与章节不匹配';
      final uri = Uri.tryParse(source.url);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        return '该章没有可下载的音频地址';
      }

      client = _clientFactory();
      final request = await client.openUrl('GET', uri);
      if (received > 0) request.headers.add('Range', 'bytes=$received-');
      request.headers.add('Accept-Encoding', 'identity');
      final response = await request.close();
      if (response.statusCode == 403 || response.statusCode == 410) {
        return 'stale-url';
      }
      var expectedTotal = -1;
      if (response.statusCode == 206) {
        final range = _parseContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        if (range == null || range.start != received) return '续传响应范围无效';
        final responseBytes = range.end - range.start + 1;
        if (response.contentLength >= 0 &&
            response.contentLength != responseBytes) {
          return '续传响应长度无效';
        }
        if (range.total == null || range.total! <= range.end) {
          return '服务器未提供有效的文件总长度';
        }
        expectedTotal = range.total!;
      } else if (response.statusCode == 200) {
        if (received > 0) {
          // 服务器忽略了 Range：已续字节不可信，从头再来。
          received = 0;
          await partFile.delete();
        }
        if (response.contentLength >= 0) expectedTotal = response.contentLength;
      } else {
        return '下载失败（HTTP ${response.statusCode}）';
      }

      sink = await partFile.open(mode: FileMode.append);
      task.snapshot = task.snapshot.copyWith(
        received: received,
        total: expectedTotal >= 0 ? expectedTotal : null,
        clearTotal: expectedTotal < 0,
      );
      _publish();

      const chunkBytes = 256 * 1024;
      var sincePublish = 0;
      await for (final chunk in response) {
        if (task.abortReason != null) return null;
        await sink.writeFrom(chunk);
        received += chunk.length;
        sincePublish += chunk.length;
        if (sincePublish >= chunkBytes) {
          sincePublish = 0;
          task.snapshot = task.snapshot.copyWith(received: received);
          _publish();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      client.close(force: true);
      client = null;

      if (expectedTotal < 0) return '无法确认下载完整性（服务器未提供总长度）';
      if (received != expectedTotal) return '下载不完整';
      try {
        await partFile.rename(finalPath);
      } on FileSystemException {
        // 同名终稿已存在（重复下载竞态）：以已存在文件为准。
        await partFile.delete();
      }
      await _store.saveChapter(
        CachedAudioChapter(
          bookId: task.snapshot.bookId,
          itemId: itemId,
          toneId: toneId,
          title: task.snapshot.title,
          index: task.snapshot.index,
          keyHex: source.keyHex,
          bytes: received,
          filePath: finalPath,
          cachedAt: DateTime.now().millisecondsSinceEpoch,
          durationMs: source.duration?.inMilliseconds,
        ),
      );
      task.snapshot = task.snapshot.copyWith(
        status: AudioDownloadStatus.completed,
        received: received,
        total: received,
        clearError: true,
      );
      return null;
    } on FileSystemException catch (error) {
      return '写入失败：${error.osError?.message ?? error.message}';
    } on Exception catch (error) {
      return error.toString();
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client?.close(force: true);
    }
  }

  static String _fileName(String itemId, String toneId) =>
      '${itemId}__$toneId.m4a';

  /// `bytes <start>-<end>/<total>`；格式不符就当作没有 Range 支持。
  static _ContentRange? _parseContentRange(String? header) {
    if (header == null) return null;
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
    ).firstMatch(header.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    if (start == null || end == null || end < start) return null;
    final total = match.group(3) == '*' ? null : int.tryParse(match.group(3)!);
    return _ContentRange(start, end, total);
  }
}

class _MutableTask {
  _MutableTask(this.snapshot);

  AudioDownloadTask snapshot;

  /// 用户中断信号（`paused` / `discarded`）。只由暂停/放弃动作设置。
  String? abortReason;

  /// 每轮 resume 自增；收尾循环靠它识别「这轮已被新一轮取代」。
  int generation = 0;

  void abort(String reason) => abortReason = reason;
}

@immutable
class _ContentRange {
  const _ContentRange(this.start, this.end, this.total);

  final int start;
  final int end;
  final int? total;
}
