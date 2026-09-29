import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import 'api_client.dart';
import 'drama_download_store.dart';
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
  });

  final String seriesId;
  final String itemId;
  final String title;
  final int index;
  final DramaDownloadStatus status;
  final int received;
  final int? total;
  final String? error;

  double? get progress => total == null || total! <= 0
      ? null
      : (received / total!).clamp(0.0, 1.0);

  DramaDownloadTask copyWith({
    DramaDownloadStatus? status,
    int? received,
    int? total,
    String? error,
    bool clearError = false,
  }) => DramaDownloadTask(
    seriesId: seriesId,
    itemId: itemId,
    title: title,
    index: index,
    status: status ?? this.status,
    received: received ?? this.received,
    total: total ?? this.total,
    error: clearError ? null : (error ?? this.error),
  );
}

/// 短剧离线下载引擎：按「集」建任务，[concurrency] 并发，断点续传，
/// 失败标 failed 不拖垮队列（与官方 SeriesDownloadManager 的 3 并发 +
/// 状态机同构，引擎换成 dart:io 直连 CDN）。
///
/// 文件形态：`<itemId>.mp4.part` 下载中、`.mp4` 完成；半成品跨启动自动
/// 续传（同集同名，Range 从已有字节继续）。落盘的是**原始加密字节**，
/// keyHex 只在完成记录里登记，磁盘上永远没有明文。
class DramaDownloader extends ValueNotifier<List<DramaDownloadTask>> {
  DramaDownloader({
    DramaDownloadStore? store,
    Future<EpisodeSource> Function(Chapter episode)? resolve,
    HttpClient Function()? clientFactory,
    this.concurrency = 3,
  }) : _store = store ?? HiveDramaDownloadStore.instance,
       _resolve = resolve ?? _defaultResolve,
       _clientFactory = clientFactory ?? HttpClient.new,
       super(const []) {
    // 管理页删记录（单集/整剧/清空）后，引擎里那条 completed 旧任务必须
    // 一起忘掉：否则 enqueue 会把该 itemId 当「已下载」跳过，用户点重新
    // 缓存没有任何反应，下载弹窗还会把删掉的集显示成「已缓存」。
    _store.changes.addListener(_onStoreChanged);
  }

  static final DramaDownloader instance = DramaDownloader();

  final DramaDownloadStore _store;
  final Future<EpisodeSource> Function(Chapter episode) _resolve;
  final HttpClient Function() _clientFactory;
  final int concurrency;

  final Map<String, _MutableTask> _tasks = {};
  final Map<String, _MutableTask> _active = {};
  bool _pumping = false;

  /// 官方 onNetChangeCheck 的本地等价：断网或只剩移动网络时全部暂停
  /// （半成品保留，恢复由用户在管理页点继续）。main.dart 把
  /// connectivity_plus 的流折叠成这两个布尔喂进来。
  void updateConnectivity({required bool online, required bool metered}) {
    if (online && !metered) return;
    pauseAll(reason: online ? null : '网络已断开，下载已暂停');
  }

  /// 入队若干集（已在队列/已完成的集自动跳过）。目录先落库，管理页
  /// 立即可见这部剧。
  Future<void> enqueue({
    required CachedDrama drama,
    required List<Chapter> episodes,
  }) async {
    if (episodes.isEmpty) return;
    await _store.ensureCatalogue(drama);
    var changed = false;
    for (final (index, episode) in episodes.indexed) {
      if (_tasks.containsKey(episode.itemId)) continue;
      if (await _store.isDownloaded(episode.itemId)) continue;
      _tasks[episode.itemId] = _MutableTask(
        DramaDownloadTask(
          seriesId: drama.id,
          itemId: episode.itemId,
          title: episode.title,
          index: index,
          status: DramaDownloadStatus.waiting,
        ),
      );
      changed = true;
    }
    if (changed) _publish();
    unawaited(_pump());
  }

  /// 当前剧集的在队/进行中任务（管理页与弹窗合并渲染用）。
  List<DramaDownloadTask> tasksFor(String seriesId) => [
    for (final task in value)
      if (task.seriesId == seriesId) task,
  ];

  void pause(String itemId) {
    final task = _tasks[itemId];
    if (task == null) return;
    if (task.snapshot.status == DramaDownloadStatus.waiting) {
      // 还没轮到跑的集：直接置 paused，别让它被 _pump 捡走。
      task.snapshot = task.snapshot.copyWith(
        status: DramaDownloadStatus.paused,
      );
      _publish();
    } else if (task.snapshot.status == DramaDownloadStatus.downloading) {
      // 在跑的集：快照先改成 paused（UI 立即响应），运行循环在下一个
      // 检查点退出；并发槽位要等 _run 收敛才真正让出。
      task.abort('paused');
      task.snapshot = task.snapshot.copyWith(
        status: DramaDownloadStatus.paused,
      );
      _publish();
      unawaited(_pump());
    }
  }

  void pauseAll({String? reason}) {
    var changed = false;
    for (final task in _tasks.values) {
      if (task.snapshot.status == DramaDownloadStatus.waiting ||
          task.snapshot.status == DramaDownloadStatus.downloading) {
        final wasDownloading =
            task.snapshot.status == DramaDownloadStatus.downloading;
        if (wasDownloading) task.abort('paused');
        task.snapshot = task.snapshot.copyWith(
          status: DramaDownloadStatus.paused,
          error: reason,
        );
        changed = true;
      }
    }
    if (changed) _publish();
    unawaited(_pump());
  }

  void resume(String itemId) {
    final task = _tasks[itemId];
    if (task == null) return;
    if (task.snapshot.status == DramaDownloadStatus.paused ||
        task.snapshot.status == DramaDownloadStatus.failed) {
      task.snapshot = task.snapshot.copyWith(
        status: DramaDownloadStatus.waiting,
        clearError: true,
      );
      _publish();
      unawaited(_pump());
    }
  }

  void resumeAll() {
    for (final task in _tasks.values) {
      if (task.snapshot.status == DramaDownloadStatus.paused ||
          task.snapshot.status == DramaDownloadStatus.failed) {
        task.snapshot = task.snapshot.copyWith(
          status: DramaDownloadStatus.waiting,
          clearError: true,
        );
      }
    }
    _publish();
    unawaited(_pump());
  }

  /// 放弃一个未完成任务并清掉半成品。已完成集的删除走 store（管理页）。
  Future<void> discard(String itemId) async {
    final task = _tasks.remove(itemId);
    task?.abort('discarded');
    _active.remove(itemId);
    try {
      final dir = await _store.directory();
      await File('${dir.path}${Platform.pathSeparator}$itemId.mp4.part')
          .delete();
    } on FileSystemException catch (_) {
    } on ArgumentError catch (_) {}
    _publish();
    unawaited(_pump());
  }

  void _onStoreChanged() {
    unawaited(_forgetRemovedDownloads());
  }

  /// 清掉 store 里已经不存在的已完成任务（在途/暂停任务保留：半成品跨
  /// 启动续传靠它们）。删除是用户动作，任务态必须跟着记录一起走。
  Future<void> _forgetRemovedDownloads() async {
    try {
      final completed = [
        for (final entry in _tasks.entries)
          if (entry.value.snapshot.status == DramaDownloadStatus.completed)
            entry.key,
      ];
      if (completed.isEmpty) return;
      var changed = false;
      for (final itemId in completed) {
        if (await _store.isDownloaded(itemId)) continue;
        _tasks.remove(itemId);
        _active.remove(itemId);
        changed = true;
      }
      if (changed) _publish();
    } catch (_) {
      // store 不可用（箱已关）：任务留着，下一次变更再清。
    }
  }

  void _publish() {
    value = [
      for (final task in _tasks.values) task.snapshot,
    ];
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_active.length < concurrency) {
        final next = _tasks.values
            .where((task) => task.snapshot.status == DramaDownloadStatus.waiting)
            .fold<_MutableTask?>(null, (best, task) {
          if (best == null || task.snapshot.index < best.snapshot.index) {
            return task;
          }
          return best;
        });
        if (next == null) return;
        final running = next;
        running.snapshot = running.snapshot.copyWith(
          status: DramaDownloadStatus.downloading,
        );
        _active[running.snapshot.itemId] = running;
        _publish();
        unawaited(_run(running));
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(_MutableTask task) async {
    var refreshed = false;
    while (true) {
      final reason = await _runOnce(task);
      if (reason == null || task.abortReason != null) break;
      // CDN 直链可能过期（403/410）：重取一次取流地址再续。
      if (reason == 'stale-url' && !refreshed) {
        refreshed = true;
        continue;
      }
      break;
    }
    _active.remove(task.snapshot.itemId);
    if (task.abortReason == 'paused') {
      task.snapshot = task.snapshot.copyWith(status: DramaDownloadStatus.paused);
    } else if (task.abortReason == 'discarded') {
      return;
    } else if (task.snapshot.status != DramaDownloadStatus.completed) {
      task.snapshot = task.snapshot.copyWith(
        status: DramaDownloadStatus.failed,
      );
    }
    _publish();
    unawaited(_pump());
  }

  /// 跑一次下载（每次都会重新 resolve 取流地址）。返回 null 表示终态
  /// （完成或用户暂停/放弃）；返回 'stale-url' 表示直链失效可重试；
  /// 其他值=失败原因。
  Future<String?> _runOnce(_MutableTask task) async {
    HttpClient? client;
    RandomAccessFile? sink;
    try {
      final itemId = task.snapshot.itemId;
      final dir = await _store.directory();
      final finalPath = '${dir.path}${Platform.pathSeparator}$itemId.mp4';
      final partFile = File('$finalPath.part');
      var received = await partFile.exists() ? await partFile.length() : 0;

      final episode = Chapter(
        itemId: itemId,
        title: task.snapshot.title,
        volumeName: '',
      );
      final source = await _resolve(episode);
      if (task.abortReason != null) return null;
      final variant = _pickVariant(source);
      if (variant == null) return '该集没有可下载的播放地址';

      client = _clientFactory();
      final request = await client.openUrl('GET', Uri.parse(variant.url));
      if (received > 0) request.headers.add('Range', 'bytes=$received-');
      request.headers.add('Accept-Encoding', 'identity');
      final response = await request.close();
      // CDN 直链可能过期：403/410 时放弃本次尝试，外层重取一次地址再续
      // （每次 _runOnce 都会重新 resolve，天然拿到新链）。
      if (response.statusCode == 403 || response.statusCode == 410) {
        return 'stale-url';
      }
      if (response.statusCode == 206) {
        // 续传成立。
      } else if (response.statusCode == 200) {
        if (received > 0) {
          // 服务器忽略了 Range：已续的字节不可信，从头再来。
          received = 0;
          await partFile.delete();
        }
      } else {
        return '下载失败（HTTP ${response.statusCode}）';
      }

      final contentLength = response.contentLength;
      sink = await partFile.open(mode: FileMode.append);
      task.snapshot = task.snapshot.copyWith(
        received: received,
        total: contentLength >= 0 ? received + contentLength : null,
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

      final total = task.snapshot.total;
      if (total != null && received != total) return '下载不完整';
      try {
        await partFile.rename(finalPath);
      } on FileSystemException {
        // 同名终稿已存在（重复下载的竞态）：以已存在文件为准。
        await partFile.delete();
      }
      await _store.saveEpisode(
        CachedEpisode(
          seriesId: task.snapshot.seriesId,
          itemId: itemId,
          title: task.snapshot.title,
          index: task.snapshot.index,
          keyHex: variant.keyHex,
          height: variant.height,
          variantName: variant.name,
          bytes: received,
          filePath: finalPath,
          cachedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      task.snapshot = task.snapshot.copyWith(
        status: DramaDownloadStatus.completed,
        received: received,
      );
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client?.close(force: true);
    }
  }

  /// 与官方一致的画质策略：固定取最高档；上游只有单流时用主地址。
  static EpisodeVariant? _pickVariant(EpisodeSource source) {
    if (source.variants.isEmpty) {
      if (source.url.isEmpty) return null;
      return EpisodeVariant(
        name: '',
        url: source.url,
        keyHex: source.keyHex,
        height: 0,
      );
    }
    return source.variants.reduce(
      (a, b) => a.height >= b.height ? a : b,
    );
  }

  /// 默认取流：绕过播放页的 2 分钟缓存直接走 `/api/content`，下载器
  /// 的生命周期独立于任何页面。这是 CDN 直链请求，不走 `_get` 漏斗
  /// （该漏斗只收番茄后端 API；视频字节本就由原生层直连 CDN）。
  static Future<EpisodeSource> _defaultResolve(Chapter episode) async {
    final response = await ApiClient.instance.content(
      episode.itemId,
      tab: '短剧',
      mode: 'stream',
    );
    return EpisodeSource.fromResponse(response);
  }
}

class _MutableTask {
  _MutableTask(this.snapshot);

  DramaDownloadTask snapshot;

  /// null=在跑；'paused'/'discarded'=请求退出。_runOnce 在每个数据块
  /// 之间检查它，保证暂停/放弃的响应延迟只有一个数据块。
  String? abortReason;

  void abort(String reason) {
    abortReason ??= reason;
  }
}
