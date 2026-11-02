import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import 'api_client.dart';
import 'drama_download_store.dart';
import 'audio_download_transfer.dart';
import 'download_resume_store.dart';
import 'episode_source_cache.dart';

enum DramaDownloadStatus { waiting, downloading, paused, completed, failed }

/// 一个下载任务的不可变快照：管理页与弹窗的渲染形态。
@immutable
class DramaDownloadTask {
  const DramaDownloadTask({
    required this.seriesId,
    required this.itemId,
    required this.title,
    required this.index,
    required this.status,
    this.received = 0,
    this.total,
    this.error,
    this.auto = false,
    this.maxHeight,
  });

  final String seriesId;
  final String itemId;
  final String title;
  final int index;
  final DramaDownloadStatus status;
  final int received;
  final int? total;
  final String? error;

  /// 「边看边往后缓存」自动排的任务（见 [CachedEpisode.auto]）。
  final bool auto;

  /// 下载画质上限（1080 / 720 / 480）；null = 取最高档。
  ///
  /// 每集实际可选档位由取流接口决定，所以这里存的是「我最多接受多高」，
  /// 由 [DramaDownloader.pickVariant] 在可选集合里挑最接近的一档。
  final int? maxHeight;

  double? get progress =>
      total == null || total! <= 0 ? null : (received / total!).clamp(0.0, 1.0);

  DramaDownloadTask copyWith({
    DramaDownloadStatus? status,
    int? received,
    int? total,
    String? error,
    bool clearError = false,
    bool clearTotal = false,
    bool? auto,
  }) => DramaDownloadTask(
    seriesId: seriesId,
    itemId: itemId,
    title: title,
    index: index,
    status: status ?? this.status,
    received: received ?? this.received,
    total: clearTotal ? null : (total ?? this.total),
    error: clearError ? null : (error ?? this.error),
    auto: auto ?? this.auto,
    maxHeight: maxHeight,
  );
}

/// Owns per-key intents and reservations until transfer, commit and cleanup settle.
class DramaDownloader extends ValueNotifier<List<DramaDownloadTask>> {
  DramaDownloader({
    DramaDownloadStore? store,
    DownloadResumeStore? resumeStore,
    Future<EpisodeSource> Function(Chapter episode)? resolve,
    HttpClient Function()? clientFactory,
    this.concurrency = 3,
    this.connectTimeout = audioDownloadConnectTimeout,
    this.readTimeout = audioDownloadReadTimeout,
  }) : _store = store ?? HiveDramaDownloadStore.instance,
       _journal = resumeStore ?? DownloadResumeStore.instance,
       _resolve = resolve ?? _defaultResolve,
       _clientFactory = clientFactory ?? HttpClient.new,
       super(const []) {
    _store.changes.addListener(_onStoreChanged);
  }

  static final DramaDownloader instance = DramaDownloader();
  static const int _maxAttempts = 3;
  final DramaDownloadStore _store;
  final DownloadResumeStore _journal;
  final Future<EpisodeSource> Function(Chapter episode) _resolve;
  final HttpClient Function() _clientFactory;
  final int concurrency;
  final Duration connectTimeout;
  final Duration readTimeout;
  final Map<String, _MutableTask> _tasks = {};
  final Map<String, _DramaRun> _runs = {};
  final Map<String, _DramaRun> _active = {};
  bool _pumping = false;

  void updateConnectivity({required bool online, bool metered = false}) {
    if (online && !metered) return;
    pauseAll(reason: online ? null : '网络已断开，下载已暂停');
  }

  Future<void> enqueue({
    required CachedDrama drama,
    required List<Chapter> episodes,
    bool auto = false,
    int? maxHeight,
  }) async {
    if (episodes.isEmpty) return;
    if (drama.id.isEmpty) throw ArgumentError('Empty series id');
    for (final episode in episodes) {
      DownloadKey(DownloadKind.drama, episode.itemId);
    }
    final pending = <(String, _MutableTask)>[];
    final positions = <String, int>{
      for (final (index, episode) in drama.episodes.indexed)
        episode.itemId: index,
    };
    for (final (index, chapter) in episodes.indexed) {
      final downloadKey = DownloadKey(DownloadKind.drama, chapter.itemId);
      final key = downloadKey.itemId;
      var task = _tasks[key];
      if (task == null) {
        task = _MutableTask(
          DramaDownloadTask(
            seriesId: drama.id,
            itemId: chapter.itemId,

            title: chapter.title,
            index: positions[chapter.itemId] ?? index,
            status: DramaDownloadStatus.waiting,
            auto: auto,
            maxHeight: maxHeight,
          ),
          drama,
        );
        _tasks[key] = task;
      } else {
        if (!auto && task.snapshot.auto) {
          task.snapshot = task.snapshot.copyWith(auto: false);
        }
        if (task.snapshot.status == DramaDownloadStatus.paused ||
            task.snapshot.status == DramaDownloadStatus.failed ||
            task.snapshot.status == DramaDownloadStatus.completed) {
          _resumeTask(task);
        }
      }
      pending.add((key, task));
    }
    _publish();
    try {
      for (final (key, _) in pending) {
        await _waitDeletion(key);
      }
      if (pending.any((entry) => identical(_tasks[entry.$1], entry.$2))) {
        await _store.ensureCatalogue(drama);
        for (final (key, task) in pending) {
          if (identical(_tasks[key], task)) task.prepared = true;
        }
      }
    } catch (error) {
      for (final (key, task) in pending) {
        if (identical(_tasks[key], task) &&
            !_active.containsKey(key) &&
            task.snapshot.status == DramaDownloadStatus.waiting) {
          task.snapshot = task.snapshot.copyWith(
            status: DramaDownloadStatus.failed,
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

  List<DramaDownloadTask> tasksFor(String seriesId) => [
    for (final task in value)
      if (task.seriesId == seriesId) task,
  ];
  void pause(String itemId) => _pauseTask(_tasks[itemId]);

  void _pauseTask(_MutableTask? task, {String? reason}) {
    if (task == null ||
        (task.snapshot.status != DramaDownloadStatus.waiting &&
            task.snapshot.status != DramaDownloadStatus.downloading)) {
      return;
    }
    final run = _runs[task.snapshot.itemId];
    if (run != null && identical(run.task, task) && !run.pause()) return;
    task.snapshot = task.snapshot.copyWith(
      status: DramaDownloadStatus.paused,
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

  void resume(String itemId) {
    final task = _tasks[itemId];
    if (task == null) return;
    if (task.snapshot.status == DramaDownloadStatus.paused ||
        task.snapshot.status == DramaDownloadStatus.failed) {
      _resumeTask(task);
      unawaited(_prepareForResume(task.snapshot.itemId, task));
      _publish();
      unawaited(_retryBlocked(task.snapshot.itemId));
      unawaited(_pump());
    }
  }

  void resumeAll() {
    for (final task in _tasks.values) {
      if (task.snapshot.status == DramaDownloadStatus.paused ||
          task.snapshot.status == DramaDownloadStatus.failed) {
        _resumeTask(task);
        unawaited(_prepareForResume(task.snapshot.itemId, task));
        unawaited(_retryBlocked(task.snapshot.itemId));
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
      await _store.ensureCatalogue(task.catalogue);
      if (!identical(_tasks[key], task) || task.generation != generation) {
        return;
      }
      task.prepared = true;
    } catch (error) {
      if (identical(_tasks[key], task) &&
          task.generation == generation &&
          task.snapshot.status == DramaDownloadStatus.waiting) {
        task.snapshot = task.snapshot.copyWith(
          status: DramaDownloadStatus.failed,
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
      status: DramaDownloadStatus.waiting,
      clearError: true,
    );
  }

  // Install the deletion reservation before the first await. The run alone
  // writes its journal; discard waits for all submitted writes and cleanup.
  Future<void> discard(String itemId) {
    final downloadKey = DownloadKey(DownloadKind.drama, itemId);
    final key = itemId;
    final task = _tasks.remove(key);
    final existing = _runs[key];
    final run = existing ?? _DramaRun(downloadKey, task);
    _runs[key] = run;
    run.discard();
    _publish();
    if (existing == null) {
      unawaited(_deleteIdle(key, run));
    } else if (run.settled) {
      return _retryCleanup(key, run);
    }
    return run.terminal.then((_) {
      if (run.cleanupError != null) throw run.cleanupError!;
    });
  }

  Future<void> _deleteIdle(String key, _DramaRun run) async {
    try {
      await run.closeIO();
      await _cleanup(run);
    } catch (error) {
      run.cleanupError = error;
    } finally {
      _finish(key, run);
    }
  }

  Future<void> _retryCleanup(String key, _DramaRun run) {
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
            status: task.snapshot.status == DramaDownloadStatus.failed
                ? DramaDownloadStatus.waiting
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
      status: task.snapshot.status == DramaDownloadStatus.paused
          ? DramaDownloadStatus.paused
          : DramaDownloadStatus.failed,
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
        if (entry.value.snapshot.status == DramaDownloadStatus.completed &&
            (onlyKey == null || entry.key == onlyKey))
          entry,
    ];
    try {
      for (final entry in completed) {
        final key = entry.key;
        final task = entry.value;
        final generation = task.generation;
        final stillThere = await _store.isDownloaded(task.snapshot.itemId);
        if (stillThere ||
            !identical(_tasks[key], task) ||
            task.generation != generation ||
            task.snapshot.status != DramaDownloadStatus.completed ||
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
              task.snapshot.status != DramaDownloadStatus.waiting ||
              _runs.containsKey(entry.key)) {
            continue;
          }
          if (next == null || task.snapshot.index < next.snapshot.index) {
            next = task;
          }
        }
        if (next == null) return;
        final task = next;
        final key = task.snapshot.itemId;
        final run = _DramaRun(
          DownloadKey(DownloadKind.drama, task.snapshot.itemId),
          task,
        );
        _runs[key] = run;
        _active[key] = run;
        task.snapshot = task.snapshot.copyWith(
          status: DramaDownloadStatus.downloading,
        );
        _publish();
        unawaited(_run(key, run));
      }
    } finally {
      _pumping = false;
    }
  }

  void _check(String key, _DramaRun run) {
    run.check();
    if (!identical(_runs[key], run) ||
        !identical(_tasks[key], run.task) ||
        run.task!.generation != run.generation) {
      throw DownloadCancelled();
    }
  }

  Future<void> _run(String key, _DramaRun run) async {
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
        await _store.ensureCatalogue(task.catalogue);
        _check(key, run);
      }
      if (!await _recover(key, run)) {
        var attempt = 0;
        var refreshed = false;
        while (true) {
          _check(key, run);
          try {
            final source = await _resolve(
              Chapter(
                itemId: run.key.itemId,
                title: task.snapshot.title,
                volumeName: '',
              ),
            );
            _check(key, run);
            final variant = pickVariant(
              source,
              maxHeight: task.snapshot.maxHeight,
            );
            final uri = variant == null ? null : Uri.tryParse(variant.url);
            if (uri == null ||
                (uri.scheme != 'https' && uri.scheme != 'http') ||
                uri.host.isEmpty) {
              throw const DownloadTransferFailure('该集没有可下载的播放地址');
            }
            await transferDownload(
              run: run,
              journal: _journal,
              source: DownloadSource(
                uri: uri,
                containerId: task.snapshot.seriesId,
                keyHex: variant!.keyHex,
                rendition: variant.name,
                height: variant.height,
              ),
              record: _record(run),
              clientFactory: _clientFactory,
              connectTimeout: connectTimeout,
              readTimeout: readTimeout,
              progress: (received, total) {
                if (identical(_tasks[key], task) &&
                    task.generation == run.generation) {
                  task.snapshot = task.snapshot.copyWith(
                    received: received,
                    total: total,
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
              rethrow;
            }
            await Future<void>.delayed(Duration(milliseconds: 900 * attempt));
            _check(key, run);
          }
        }
      }
      if (run.stage == DownloadRunStage.transferring) _check(key, run);
      if (!run.discardRequested &&
          !task.snapshot.auto &&
          (run.entry?.record?.auto ?? run.existingCached?.auto ?? false)) {
        if (run.stage != DownloadRunStage.committing) _check(key, run);
        run.stage = DownloadRunStage.committing;
        run.entry ??= _entryFromCompleted(run.key, run.existingCached!);
        run.ownsFinal = true;
        await _promoteManual(run);
        if (run.entry!.stage != DownloadResumeStage.discarding &&
            !run.discardRequested) {
          await _journal.remove(run.key);
        }
      }
      if (!run.discardRequested &&
          identical(_tasks[key], task) &&
          task.generation == run.generation) {
        task.snapshot = task.snapshot.copyWith(
          status: DramaDownloadStatus.completed,
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
          status: DramaDownloadStatus.failed,
          error: '$error',
        );
      }
      debugPrint('[drama-download] ${task.snapshot.title}: $error');
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

  void _finish(String key, _DramaRun run) {
    if (identical(_active[key], run)) _active.remove(key);
    if (run.cleanupError == null && identical(_runs[key], run)) {
      _runs.remove(key);
    }
    if (run.cleanupError != null) _markCleanupBlocked(key, run.cleanupError!);
    run.settle();
    _publish();
    if (_tasks[key]?.snapshot.status == DramaDownloadStatus.completed &&
        !_runs.containsKey(key)) {
      unawaited(_forgetRemovedDownloads(onlyKey: key));
    }
    unawaited(_pump());
  }

  DownloadRecord _record(_DramaRun run, {int? durationMs}) => DownloadRecord(
    title: run.task!.snapshot.title,
    index: run.task!.snapshot.index,
    cachedAt: DateTime.now().millisecondsSinceEpoch,
    durationMs: durationMs,
    auto: run.task!.snapshot.auto,
  );

  Future<bool> _recover(String key, _DramaRun run) async {
    final files = run.files!;
    final entry = run.entry;
    final cached = await _store.episode(run.key.itemId);
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
        run.existingCached = cached;
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
    if (identity.containerId != run.task!.snapshot.seriesId) {
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
        (cached != null && !entry.matchesDrama(cached, files.finalFile.path))) {
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

  Future<void> _commit(String key, _DramaRun run) async {
    _check(key, run);
    // Linearization: pause after this point cannot hide a submitted commit.
    run.stage = DownloadRunStage.committing;
    final files = run.files!;
    final oldRecord = run.entry!.record;
    final ready = run.entry!.at(
      DownloadResumeStage.ready,
      record: oldRecord == null
          ? _record(run)
          : DownloadRecord(
              title: oldRecord.title,
              index: oldRecord.index,
              cachedAt: oldRecord.cachedAt,
              auto: run.task!.snapshot.auto && oldRecord.auto,
            ),
    );
    await _journal.write(ready);
    run.entry = ready;
    if (!run.ownsFinal) {
      await files.promote(ready.identity!.total);
      run.ownsFinal = true;
    }
    if (await files.length(files.finalFile) != ready.identity!.total) {
      throw const DownloadTransferFailure('提交终稿文件长度冲突');
    }
    final promoted = ready.at(DownloadResumeStage.promoted);
    await _journal.write(promoted);
    run.entry = promoted;
    final existing = await _store.episode(run.key.itemId);
    if (existing != null &&
        !promoted.matchesDrama(existing, files.finalFile.path)) {
      throw const DownloadTransferFailure('提交遇到其他下载记录，已保留');
    }
    await _store.saveEpisode(promoted.dramaEpisode(files.finalFile.path));
    run.completedBytes = promoted.identity!.total;
    if (!run.discardRequested) await _journal.remove(run.key);
  }

  Future<void> _cleanup(_DramaRun run) async {
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
    final cached = await _store.episode(run.key.itemId);
    if (cached != null &&
        run.previousEntry?.matchesDrama(cached, files.finalFile.path) == true) {
      entry = run.previousEntry!;
      marker = entry.at(
        DownloadResumeStage.discarding,
        finalOwned: run.ownsFinal || entry.finalOwned,
      );
      await _journal.write(marker);
      run.entry = marker;
    }
    final partLength = await files.length(files.part);
    final finalLength = await files.length(files.finalFile);
    final finalOwned = marker.finalOwned;
    if (marker.record != null &&
        cached != null &&
        !marker.matchesDrama(cached, files.finalFile.path)) {
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
      await _store.removeEpisode(run.key.itemId);
      final remaining = await _store.episode(run.key.itemId);
      if (remaining != null) throw const DownloadTransferFailure('下载记录未清除');
    }
    if (finalOwned) await files.delete(files.finalFile);
    await files.delete(files.part);
    await _journal.remove(run.key);
    run.entry = null;
    run.ownsFinal = false;
  }

  /// 与官方一致的画质策略：固定取最高档；上游只有单流时用主地址。
  /// 在一集的可选档位里挑一档下载。
  ///
  /// [maxHeight] 为 null 时取最高档（原来的行为）。给了上限就取「不超过
  /// 上限的最高一档」——省流量的人要的是 720P，给他 480P 是错的；如果这集
  /// 最小的一档也比上限高（比如只有 1080P），那就用最小的一档，总不能
  /// 因为挑不到就失败。
  @visibleForTesting
  static EpisodeVariant? pickVariant(EpisodeSource source, {int? maxHeight}) {
    if (source.variants.isEmpty) {
      if (source.url.isEmpty) return null;
      return EpisodeVariant(
        name: '',
        url: source.url,
        keyHex: source.keyHex,
        height: 0,
      );
    }
    if (maxHeight == null) {
      return source.variants.reduce((a, b) => a.height >= b.height ? a : b);
    }
    // height <= 0 表示上游没给高度，只能当作最差候选。
    final known = source.variants.where((v) => v.height > 0).toList();
    if (known.isEmpty) {
      return source.variants.reduce((a, b) => a.height >= b.height ? a : b);
    }
    final fits = known.where((v) => v.height <= maxHeight).toList()
      ..sort((a, b) => b.height.compareTo(a.height));
    if (fits.isNotEmpty) return fits.first;
    return known.reduce((a, b) => a.height <= b.height ? a : b);
  }

  /// 默认取流：绕过播放页的 2 分钟缓存直接走 `/api/content`，下载器
  /// 的生命周期独立于任何页面。这是 CDN 直链请求，不走 `_get` 漏斗
  /// （该漏斗只收后端 API；视频字节本就由原生层直连 CDN）。
  static Future<EpisodeSource> _defaultResolve(Chapter episode) async {
    final response = await ApiClient.instance.content(
      episode.itemId,
      tab: '短剧',
      mode: 'stream',
    );
    return EpisodeSource.fromResponse(response);
  }

  DownloadResumeEntry _entryFromCompleted(
    DownloadKey key,
    CachedEpisode cached,
  ) => DownloadResumeEntry(
    key,
    DownloadResumeStage.discarding,
    finalOwned: true,
    identity: DownloadIdentity(
      containerId: cached.seriesId,
      keyHex: cached.keyHex,
      rendition: cached.variantName,
      height: cached.height,
      total: cached.bytes,
      requestedDigest: null,
      effectiveDigest: null,
    ),
    record: DownloadRecord(
      title: cached.title,
      index: cached.index,
      cachedAt: cached.cachedAt,
      auto: cached.auto,
    ),
  );

  Future<void> _promoteManual(_DramaRun run) async {
    final entry = run.entry!;
    final record = entry.record!;
    if (run.discardRequested || run.task!.snapshot.auto || !record.auto) return;
    final manual = entry.at(
      entry.stage,
      record: DownloadRecord(
        title: record.title,
        index: record.index,
        cachedAt: record.cachedAt,
        durationMs: record.durationMs,
      ),
    );
    run.previousEntry = entry;
    if (entry.stage != DownloadResumeStage.discarding) {
      await _journal.write(manual);
    }
    run.entry = manual;
    try {
      await _store.saveEpisode(manual.dramaEpisode(run.files!.finalFile.path));
    } catch (_) {
      // A failed submitted save may have left either owned snapshot. Restore
      // the journal to the actual predecessor, never to a conflicting row.
      if (entry.stage != DownloadResumeStage.discarding) {
        final cached = await _store.episode(run.key.itemId);
        if (cached != null &&
            entry.matchesDrama(cached, run.files!.finalFile.path)) {
          await _journal.write(entry);
          run.entry = entry;
        }
      }
      rethrow;
    }
  }
}

class _MutableTask {
  _MutableTask(this.snapshot, this.catalogue);
  DramaDownloadTask snapshot;
  final CachedDrama catalogue;
  int generation = 0;
  bool prepared = false;
  bool cleanupBlocked = false;
}

class _DramaRun extends DownloadRun {
  _DramaRun(DownloadKey key, this.task) : super(key, task?.generation ?? 0);
  final _MutableTask? task;
  Future<void>? cleanupOperation;
  int completedBytes = 0;
  DownloadResumeEntry? previousEntry;
  CachedEpisode? existingCached;
}
