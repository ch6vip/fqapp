import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/chapter_media.dart';
import '../models/media_item.dart';
import 'api_client.dart';
import 'audio_download_store.dart';
import 'audio_download_transfer.dart';
import 'download_resume_store.dart';

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

/// Owns per-key intents and reservations until transfer, commit and cleanup settle.
class AudioDownloader extends ValueNotifier<List<AudioDownloadTask>> {
  AudioDownloader({
    AudioDownloadStore? store,
    DownloadResumeStore? resumeStore,
    Future<AudioSource> Function(String bookId, String itemId, String toneId)?
    resolve,
    HttpClient Function()? clientFactory,
    this.concurrency = 2,
    this.connectTimeout = audioDownloadConnectTimeout,
    this.readTimeout = audioDownloadReadTimeout,
  }) : _store = store ?? HiveAudioDownloadStore.instance,
       _journal =
           resumeStore ??
           (store == null || store is HiveAudioDownloadStore
               ? DownloadResumeStore.instance
               : DownloadResumeStore.memory()),
       _resolve = resolve ?? _defaultResolve,
       _clientFactory = clientFactory ?? HttpClient.new,
       super(const []) {
    _store.changes.addListener(_onStoreChanged);
  }

  static final AudioDownloader instance = AudioDownloader();
  static const int _maxAttempts = 3;
  final AudioDownloadStore _store;
  final DownloadResumeStore _journal;
  final Future<AudioSource> Function(
    String bookId,
    String itemId,
    String toneId,
  )
  _resolve;
  final HttpClient Function() _clientFactory;
  final int concurrency;
  final Duration connectTimeout;
  final Duration readTimeout;
  final Map<String, _MutableTask> _tasks = {};
  final Map<String, _AudioRun> _runs = {};
  final Map<String, _AudioRun> _active = {};
  bool _pumping = false;

  void updateConnectivity({required bool online, bool metered = false}) {
    if (online && !metered) return;
    pauseAll(reason: online ? null : '网络已断开，下载已暂停');
  }

  Future<void> enqueue({
    required CachedAudioBook book,
    required List<Chapter> chapters,
  }) async {
    if (chapters.isEmpty) return;
    if (book.bookId.isEmpty) throw ArgumentError('Empty book id');
    for (final chapter in chapters) {
      DownloadKey(DownloadKind.audio, chapter.itemId, book.toneId);
    }
    final pending = <(String, _MutableTask)>[];

    for (final (index, chapter) in chapters.indexed) {
      final downloadKey = DownloadKey(
        DownloadKind.audio,
        chapter.itemId,
        book.toneId,
      );
      final key = taskId(downloadKey.itemId, downloadKey.toneId);
      var task = _tasks[key];
      if (task == null) {
        task = _MutableTask(
          AudioDownloadTask(
            bookId: book.bookId,
            itemId: chapter.itemId,
            toneId: book.toneId,
            title: chapter.title,
            index: index,
            status: AudioDownloadStatus.waiting,
          ),
          book,
        );
        _tasks[key] = task;
      } else {
        if (task.snapshot.status == AudioDownloadStatus.paused ||
            task.snapshot.status == AudioDownloadStatus.failed ||
            task.snapshot.status == AudioDownloadStatus.completed) {
          _resumeTask(task);
        }
      }
      pending.add((key, task));
    }
    _publish();
    try {
      if (pending.any((entry) => identical(_tasks[entry.$1], entry.$2))) {
        await _store.ensureBook(book);
        for (final (key, task) in pending) {
          if (identical(_tasks[key], task)) task.prepared = true;
        }
      }
    } catch (error) {
      for (final (key, task) in pending) {
        if (identical(_tasks[key], task) &&
            !_active.containsKey(key) &&
            task.snapshot.status == AudioDownloadStatus.waiting) {
          task.snapshot = task.snapshot.copyWith(
            status: AudioDownloadStatus.failed,
            error: '$error',
          );
        }
      }
      rethrow;
    } finally {
      _publish();
      unawaited(_pump());
    }
  }

  static String taskId(String itemId, String toneId) => '$itemId|$toneId';

  String _keyOf(String itemId, String toneId) {
    if (toneId.isNotEmpty) return taskId(itemId, toneId);
    for (final key in _tasks.keys) {
      if (key.startsWith('$itemId|')) return key;
    }
    return taskId(itemId, toneId);
  }

  void clearFinished() {
    _tasks.removeWhere(
      (key, task) =>
          !_runs.containsKey(key) &&
          (task.snapshot.status == AudioDownloadStatus.completed ||
              task.snapshot.status == AudioDownloadStatus.failed),
    );
    _publish();
  }

  void pause(String itemId, {String toneId = ''}) =>
      _pauseTask(_tasks[_keyOf(itemId, toneId)]);

  void _pauseTask(_MutableTask? task, {String? reason}) {
    if (task == null ||
        (task.snapshot.status != AudioDownloadStatus.waiting &&
            task.snapshot.status != AudioDownloadStatus.downloading)) {
      return;
    }
    final run = _runs[taskId(task.snapshot.itemId, task.snapshot.toneId)];
    if (run != null && identical(run.task, task) && !run.pause()) return;
    task.snapshot = task.snapshot.copyWith(
      status: AudioDownloadStatus.paused,
      error: reason,
    );
    _publish();
    unawaited(_pump());
  }

  void pauseAll({String? reason}) {
    for (final task in _tasks.values.toList()) {
      _pauseTask(task, reason: reason);
    }
  }

  void resume(String itemId, {String toneId = ''}) {
    final task = _tasks[_keyOf(itemId, toneId)];
    if (task == null) return;
    if (task.snapshot.status == AudioDownloadStatus.paused ||
        task.snapshot.status == AudioDownloadStatus.failed) {
      _resumeTask(task);
      unawaited(
        _prepareForResume(
          taskId(task.snapshot.itemId, task.snapshot.toneId),
          task,
        ),
      );
      _publish();
      unawaited(
        _retryBlocked(taskId(task.snapshot.itemId, task.snapshot.toneId)),
      );
      unawaited(_pump());
    }
  }

  void resumeAll() {
    for (final task in _tasks.values) {
      if (task.snapshot.status == AudioDownloadStatus.paused ||
          task.snapshot.status == AudioDownloadStatus.failed) {
        _resumeTask(task);
        unawaited(
          _prepareForResume(
            taskId(task.snapshot.itemId, task.snapshot.toneId),
            task,
          ),
        );
        unawaited(
          _retryBlocked(taskId(task.snapshot.itemId, task.snapshot.toneId)),
        );
      }
    }
    _publish();
    unawaited(_pump());
  }

  Future<void> _prepareForResume(String key, _MutableTask task) async {
    if (task.prepared) return;
    final generation = task.generation;
    try {
      await _waitDeletion(key);
      if (!identical(_tasks[key], task) || task.generation != generation) {
        return;
      }
      await _store.ensureBook(task.catalogue);
      if (!identical(_tasks[key], task) || task.generation != generation) {
        return;
      }
      task.prepared = true;
    } catch (error) {
      if (identical(_tasks[key], task) &&
          task.generation == generation &&
          task.snapshot.status == AudioDownloadStatus.waiting) {
        task.snapshot = task.snapshot.copyWith(
          status: AudioDownloadStatus.failed,
          error: '$error',
        );
      }
    } finally {
      _publish();
      unawaited(_pump());
    }
  }

  void _resumeTask(_MutableTask task) {
    task.generation++;
    task.cleanupBlocked = false;
    task.snapshot = task.snapshot.copyWith(
      status: AudioDownloadStatus.waiting,
      clearError: true,
    );
  }

  // Install the deletion reservation before the first await. The run alone
  // writes its journal; discard waits for all submitted writes and cleanup.
  Future<void> discard(String itemId, {String toneId = ''}) {
    var resolvedTone = toneId;
    if (resolvedTone.isEmpty) {
      for (final task in _tasks.values) {
        if (task.snapshot.itemId == itemId) {
          resolvedTone = task.snapshot.toneId;
          break;
        }
      }
    }
    if (resolvedTone.isEmpty) {
      // Preserve the old no-op for an unknown item while still rejecting an
      // unsafe id before any file or journal operation.
      try {
        DownloadKey(DownloadKind.audio, itemId, 'unused');
      } catch (error, stack) {
        return Future<void>.error(error, stack);
      }
      return Future<void>.value();
    }
    late final DownloadKey downloadKey;
    try {
      downloadKey = DownloadKey(DownloadKind.audio, itemId, resolvedTone);
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
    final key = taskId(itemId, resolvedTone);
    final task = _tasks.remove(key);
    final existing = _runs[key];
    final run = existing ?? _AudioRun(downloadKey, task);
    _runs[key] = run;
    run.discard();
    _publish();
    if (existing == null) {
      unawaited(_deleteIdle(key, run));
    } else if (run.settled) {
      unawaited(_retryCleanup(key, run));
    }
    // The deletion reservation is installed synchronously. Cleanup continues
    // in the background; _pump keeps a re-enqueued task waiting until the
    // reservation is gone.
    return Future<void>.value();
  }

  Future<void> _deleteIdle(String key, _AudioRun run) async {
    try {
      await run.closeIO();
      await _cleanup(run);
    } catch (error) {
      run.cleanupError = error;
    } finally {
      _finish(key, run);
    }
  }

  Future<void> _retryCleanup(String key, _AudioRun run) {
    final pending = run.cleanupOperation;
    if (pending != null) return pending;
    final operation = () async {
      try {
        await run.closeIO();
        if (run.discardRequested ||
            run.entry?.stage == DownloadResumeStage.discarding) {
          await _cleanup(run);
        }
        run.cleanupError = null;
        final task = _tasks[key];
        if (task != null && task.cleanupBlocked) {
          task.cleanupBlocked = false;
          task.snapshot = task.snapshot.copyWith(
            status: task.snapshot.status == AudioDownloadStatus.failed
                ? AudioDownloadStatus.waiting
                : null,
            clearError: true,
          );
        }
        if (identical(_runs[key], run)) _runs.remove(key);
      } catch (error) {
        run.cleanupError = error;
        rethrow;
      } finally {
        run.cleanupOperation = null;
        _publish();
        unawaited(_pump());
      }
    }();
    run.cleanupOperation = operation;
    return operation;
  }

  void _markCleanupBlocked(String key, Object error) {
    final task = _tasks[key];
    if (task == null) return;
    task.cleanupBlocked = true;
    task.prepared = false;
    task.snapshot = task.snapshot.copyWith(
      status: task.snapshot.status == AudioDownloadStatus.paused
          ? AudioDownloadStatus.paused
          : AudioDownloadStatus.failed,
      error: '清理失败：$error',
    );
  }

  Future<void> _retryBlocked(String key) async {
    final run = _runs[key];
    if (run == null || !run.settled) return;
    try {
      await _retryCleanup(key, run);
    } catch (error) {
      _markCleanupBlocked(key, error);
      _publish();
    }
  }

  Future<void> _waitDeletion(String key) async {
    final run = _runs[key];
    if (run == null) return;
    if (run.discardRequested && !run.settled) await run.terminal;
    if (identical(_runs[key], run) && run.settled) {
      await _retryCleanup(key, run);
    }
  }

  void _onStoreChanged() => unawaited(_forgetRemovedDownloads());

  Future<void> _forgetRemovedDownloads({String? onlyKey}) async {
    final completed = [
      for (final entry in _tasks.entries)
        if (entry.value.snapshot.status == AudioDownloadStatus.completed &&
            (onlyKey == null || entry.key == onlyKey))
          entry,
    ];
    try {
      for (final entry in completed) {
        final key = entry.key;
        final task = entry.value;
        final generation = task.generation;
        final stillThere = await _store.isDownloaded(
          task.snapshot.itemId,
          toneId: task.snapshot.toneId,
        );
        if (stillThere ||
            !identical(_tasks[key], task) ||
            task.generation != generation ||
            task.snapshot.status != AudioDownloadStatus.completed ||
            _runs.containsKey(key)) {
          continue;
        }
        _tasks.remove(key);
        _publish();
      }
    } catch (_) {
      // Optional store reads do not retire a live reservation.
    }
  }

  void _publish() => value = [for (final task in _tasks.values) task.snapshot];

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_active.length < concurrency) {
        _MutableTask? next;
        for (final entry in _tasks.entries) {
          final task = entry.value;
          if (!task.prepared ||
              task.snapshot.status != AudioDownloadStatus.waiting ||
              _runs.containsKey(entry.key)) {
            continue;
          }
          if (next == null || task.snapshot.index < next.snapshot.index) {
            next = task;
          }
        }
        if (next == null) return;
        final task = next;
        final key = taskId(task.snapshot.itemId, task.snapshot.toneId);
        final run = _AudioRun(
          DownloadKey(
            DownloadKind.audio,
            task.snapshot.itemId,
            task.snapshot.toneId,
          ),
          task,
        );
        _runs[key] = run;
        _active[key] = run;
        task.snapshot = task.snapshot.copyWith(
          status: AudioDownloadStatus.downloading,
        );
        _publish();
        unawaited(_run(key, run));
      }
    } finally {
      _pumping = false;
    }
  }

  void _check(String key, _AudioRun run) {
    run.check();
    if (!identical(_runs[key], run) ||
        !identical(_tasks[key], run.task) ||
        run.task!.generation != run.generation) {
      throw DownloadCancelled();
    }
  }

  Future<void> _run(String key, _AudioRun run) async {
    final task = run.task!;
    var recoveryCleanupFailed = false;
    try {
      final directory = await _store.directory();
      _check(key, run);
      run.files = await DownloadFiles.inDirectory(directory, run.key);
      _check(key, run);
      run.entry = await _journal.read(run.key);
      _check(key, run);
      if (run.entry?.stage == DownloadResumeStage.discarding) {
        try {
          await _cleanup(run);
        } catch (error) {
          recoveryCleanupFailed = true;
          run.cleanupError = error;
          rethrow;
        }
        run.stage = DownloadRunStage.transferring;
        _check(key, run);
        await _store.ensureBook(task.catalogue);
        _check(key, run);
      }
      if (!await _recover(key, run)) {
        var attempt = 0;
        var refreshed = false;
        while (true) {
          _check(key, run);
          try {
            final source = await _resolve(
              task.snapshot.bookId,
              run.key.itemId,
              run.key.toneId,
            );
            _check(key, run);
            if (source.itemId != run.key.itemId ||
                source.toneId != run.key.toneId) {
              throw const DownloadTransferFailure('取流结果与章节不匹配');
            }
            final uri = Uri.tryParse(source.url);
            if (uri == null ||
                (uri.scheme != 'https' && uri.scheme != 'http') ||
                uri.host.isEmpty) {
              throw const DownloadTransferFailure('该章没有可下载的音频地址');
            }
            await transferDownload(
              run: run,
              journal: _journal,
              source: DownloadSource(
                uri: uri,
                containerId: task.snapshot.bookId,
                keyHex: source.keyHex,
              ),
              record: _record(run, durationMs: source.duration?.inMilliseconds),
              clientFactory: _clientFactory,
              connectTimeout: connectTimeout,
              readTimeout: readTimeout,
              progress: (received, total) {
                if (identical(_tasks[key], task) &&
                    task.generation == run.generation) {
                  task.snapshot = task.snapshot.copyWith(
                    received: received,
                    total: total,
                    clearTotal: total == null,
                  );
                  _publish();
                }
              },
            );
            _check(key, run);
            await _commit(key, run);
            break;
          } on DownloadCancelled {
            rethrow;
          } catch (error) {
            if (run.stage == DownloadRunStage.committing ||
                run.cleanupError != null) {
              rethrow;
            }
            _check(key, run);
            final reason = error is Exception
                ? audioDownloadFailureReason(error)
                : '$error';
            if (reason == 'stale-url' && !refreshed) {
              refreshed = true;
              continue;
            }
            if (++attempt >= _maxAttempts ||
                !isRetryableAudioDownloadFailure(reason)) {
              throw DownloadTransferFailure(reason);
            }
            await Future<void>.delayed(Duration(milliseconds: 900 * attempt));
            _check(key, run);
          }
        }
      }
      if (run.stage == DownloadRunStage.transferring) _check(key, run);
      if (!run.discardRequested &&
          identical(_tasks[key], task) &&
          task.generation == run.generation) {
        task.snapshot = task.snapshot.copyWith(
          status: AudioDownloadStatus.completed,
          received: run.completedBytes,
          total: run.completedBytes,
          clearError: true,
        );
      }
    } on DownloadCancelled {
      // The next intent owns the UI; this run still owns its IO and cleanup.
    } catch (error) {
      if (identical(_tasks[key], task) && task.generation == run.generation) {
        task.snapshot = task.snapshot.copyWith(
          status: AudioDownloadStatus.failed,
          error: '$error',
        );
      }
      debugPrint('[audio-download] ${task.snapshot.title}: $error');
    } finally {
      try {
        await run.closeIO();
        if (!recoveryCleanupFailed) run.cleanupError = null;
        if (run.discardRequested) {
          await _cleanup(run);
          run.cleanupError = null;
        }
      } catch (error) {
        run.cleanupError = error;
        _markCleanupBlocked(key, error);
      }
      _finish(key, run);
    }
  }

  void _finish(String key, _AudioRun run) {
    if (identical(_active[key], run)) _active.remove(key);
    if (run.cleanupError == null && identical(_runs[key], run)) {
      _runs.remove(key);
    }
    if (run.cleanupError != null) _markCleanupBlocked(key, run.cleanupError!);
    run.settle();
    _publish();
    if (_tasks[key]?.snapshot.status == AudioDownloadStatus.completed &&
        !_runs.containsKey(key)) {
      unawaited(_forgetRemovedDownloads(onlyKey: key));
    }
    unawaited(_pump());
  }

  DownloadRecord _record(_AudioRun run, {int? durationMs}) => DownloadRecord(
    title: run.task!.snapshot.title,
    index: run.task!.snapshot.index,
    cachedAt: DateTime.now().millisecondsSinceEpoch,
    durationMs: durationMs,
  );

  Future<bool> _recover(String key, _AudioRun run) async {
    final files = run.files!;
    final entry = run.entry;
    final cached = await _store.chapter(run.key.itemId, toneId: run.key.toneId);
    _check(key, run);
    final partLength = await files.length(files.part);
    _check(key, run);
    final finalLength = await files.length(files.finalFile);
    _check(key, run);
    if (entry == null) {
      if (cached != null) {
        if (cached.filePath != files.finalFile.path ||
            finalLength != cached.bytes ||
            cached.bytes <= 0 ||
            partLength != null) {
          throw const DownloadTransferFailure('已下载记录与文件冲突');
        }
        run.completedBytes = cached.bytes;
        run.stage = DownloadRunStage.committing;
        await _journal.remove(run.key);
        return true;
      }
      if (finalLength != null) {
        throw const DownloadTransferFailure('未登记的终稿文件冲突');
      }
      return false;
    }
    final identity = entry.identity!;
    if (identity.containerId != run.task!.snapshot.bookId) {
      throw const DownloadTransferFailure('断点记录与目录不匹配');
    }
    final full = entry.stage != DownloadResumeStage.receiving;
    if (!full) {
      if (cached != null || finalLength != null) {
        throw const DownloadTransferFailure('断点记录与已下载文件冲突');
      }
      return false;
    }
    if ((partLength == null) == (finalLength == null) ||
        (partLength ?? finalLength) != identity.total ||
        (cached != null && !entry.matchesAudio(cached, files.finalFile.path))) {
      throw const DownloadTransferFailure('断点恢复文件或记录冲突');
    }
    run.ownsFinal = finalLength != null;
    if (cached != null && finalLength != null) {
      _check(key, run);
      run.stage = DownloadRunStage.committing;
      run.completedBytes = identity.total;

      await _journal.remove(run.key);
      return true;
    }
    if (cached != null) throw const DownloadTransferFailure('已登记记录缺少终稿');
    await _commit(key, run);
    return true;
  }

  Future<void> _commit(String key, _AudioRun run) async {
    _check(key, run);
    // Linearization: pause after this point cannot hide a submitted commit.
    run.stage = DownloadRunStage.committing;
    final files = run.files!;
    final oldRecord = run.entry!.record;
    final ready = run.entry!.at(
      DownloadResumeStage.ready,
      record: oldRecord ?? _record(run),
    );
    await _journal.write(ready);
    run.entry = ready;
    if (!run.ownsFinal) {
      final total = ready.identity!.total;
      if (await files.length(files.finalFile) != null) {
        throw const DownloadTransferFailure('提交终稿文件冲突');
      }
      if (await files.length(files.part) != total) {
        throw const DownloadTransferFailure('提交半成品文件长度冲突');
      }
      await commitAudioDownload(
        partFile: files.part,
        finalPath: files.finalFile.path,
        isAborted: () => false,
        save: () async {},
        deletePartOnConflict: false,
      );
      run.ownsFinal = true;
    }
    if (await files.length(files.finalFile) != ready.identity!.total) {
      throw const DownloadTransferFailure('提交终稿文件长度冲突');
    }
    final promoted = ready.at(DownloadResumeStage.promoted);
    await _journal.write(promoted);
    run.entry = promoted;
    final existing = await _store.chapter(
      run.key.itemId,
      toneId: run.key.toneId,
    );
    if (existing != null &&
        !promoted.matchesAudio(existing, files.finalFile.path)) {
      throw const DownloadTransferFailure('提交遇到其他下载记录，已保留');
    }
    await _store.saveChapter(promoted.audioChapter(files.finalFile.path));

    run.completedBytes = promoted.identity!.total;
    if (!run.discardRequested) await _journal.remove(run.key);
  }

  Future<void> _cleanup(_AudioRun run) async {
    run.stage = DownloadRunStage.cleaning;
    run.entry ??= await _journal.read(run.key);
    var entry =
        run.entry ??
        DownloadResumeEntry(run.key, DownloadResumeStage.discarding);
    var marker = entry.at(
      DownloadResumeStage.discarding,
      finalOwned:
          run.ownsFinal ||
          entry.finalOwned ||
          entry.stage == DownloadResumeStage.ready,
    );
    // Record deletion intent before path probes too: even a permission/IO
    // failure must leave recovery in discarding, not resume the old transfer.
    await _journal.write(marker);
    run.entry = marker;
    run.files ??= await DownloadFiles.inDirectory(
      await _store.directory(),
      run.key,
    );
    final files = run.files!;
    final cached = await _store.chapter(run.key.itemId, toneId: run.key.toneId);
    final partLength = await files.length(files.part);
    final finalLength = await files.length(files.finalFile);
    final finalOwned = marker.finalOwned;
    if (marker.record != null &&
        cached != null &&
        !marker.matchesAudio(cached, files.finalFile.path)) {
      throw const DownloadTransferFailure('放弃清理遇到其他下载记录，已保留');
    }
    if ((finalOwned &&
            finalLength != null &&
            finalLength != marker.identity?.total) ||
        (partLength != null &&
            finalLength != null &&
            marker.identity != null)) {
      throw const DownloadTransferFailure('放弃清理遇到冲突文件，已保留');
    }
    if (!finalOwned && finalLength != null && marker.identity != null) {
      throw const DownloadTransferFailure('放弃清理遇到不属于本轮的终稿，已保留');
    }
    if (marker.record != null || cached == null) {
      await _store.removeChapter(run.key.itemId, toneId: run.key.toneId);
      final remaining = await _store.chapter(
        run.key.itemId,
        toneId: run.key.toneId,
      );
      if (remaining != null) throw const DownloadTransferFailure('下载记录未清除');
    }
    if (finalOwned) await files.delete(files.finalFile);
    await files.delete(files.part);
    await _journal.remove(run.key);
    run.entry = null;
    run.ownsFinal = false;
  }

  static Future<AudioSource> _defaultResolve(
    String bookId,
    String itemId,
    String toneId,
  ) => ApiClient.instance.audioSource(itemId, bookId: bookId, toneId: toneId);
}

class _MutableTask {
  _MutableTask(this.snapshot, this.catalogue);
  AudioDownloadTask snapshot;
  final CachedAudioBook catalogue;
  int generation = 0;
  bool prepared = false;
  bool cleanupBlocked = false;
}

class _AudioRun extends DownloadRun {
  _AudioRun(DownloadKey key, this.task) : super(key, task?.generation ?? 0);
  final _MutableTask? task;
  Future<void>? cleanupOperation;
  int completedBytes = 0;
}
