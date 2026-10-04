import 'package:flutter/material.dart';

import '../services/chapter_cache_store.dart' show formatCacheBytes;
import '../services/drama_download_store.dart';
import '../services/drama_downloader.dart';

/// 短剧离线缓存管理页（官方 DownloadManagementActivity 的「已下载」tab
/// 形态）：按剧聚合的卡片 + 集级明细 + 删除（单集/整剧/全部）+ 占用统计
/// + 全部暂停/继续；下载中任务实时来自 [DramaDownloader]。
///
/// v1 无自动淘汰（官方 cacheSize=0 同策略）：占用一目了然，空间靠用户
/// 手动清理；「可用空间」行需要磁盘余量 API，暂缺，见 manifest 待验项。
class CachedDramasPage extends StatefulWidget {
  const CachedDramasPage({super.key, this.store, this.downloader});

  final DramaDownloadStore? store;
  final DramaDownloader? downloader;

  @override
  State<CachedDramasPage> createState() => _CachedDramasPageState();
}

class _CachedDramasPageState extends State<CachedDramasPage> {
  late final DramaDownloadStore _store =
      widget.store ?? HiveDramaDownloadStore.instance;
  late final DramaDownloader _downloader =
      widget.downloader ?? DramaDownloader.instance;
  List<CachedDramaSummary> _dramas = [];
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_reload);
    _downloader.addListener(_onTasksChanged);
    _reload();
  }

  @override
  void dispose() {
    _store.changes.removeListener(_reload);
    _downloader.removeListener(_onTasksChanged);
    super.dispose();
  }

  void _onTasksChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    try {
      final dramas = await _store.dramas();
      if (!mounted || generation != _generation) return;
      setState(() {
        _dramas = dramas;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = '无法读取缓存';
        });
      }
    }
  }

  Future<bool> _confirm(String title, String content) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _deleteDrama(CachedDramaSummary summary) async {
    if (!await _confirm(
      '删除《${summary.drama.title}》的缓存',
      '已下载的 ${summary.episodes.length} 集会从设备删除，联网后可重新缓存。',
    )) {
      return;
    }
    await _store.removeDrama(summary.drama.id);
  }

  Future<void> _deleteEpisode(CachedEpisode episode) async {
    if (!await _confirm('删除这一集', '联网后可重新缓存。')) return;
    await _store.removeEpisode(episode.itemId);
  }

  Future<void> _clearAll() async {
    if (!await _confirm(
      '清空全部离线缓存',
      '所有已下载的剧集会从设备删除，联网后可重新缓存。',
    )) {
      return;
    }
    for (final summary in _dramas) {
      await _store.removeDrama(summary.drama.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final episodeCount = _dramas.fold(
      0,
      (sum, item) => sum + item.episodes.length,
    );
    final bytes = _dramas.fold(0, (sum, item) => sum + item.bytes);
    final tasks = _downloader.value;
    final hasActiveTasks = tasks.any(
      (task) =>
          task.status == DramaDownloadStatus.downloading ||
          task.status == DramaDownloadStatus.waiting,
    );
    final hasPausedTasks = tasks.any(
      (task) => task.status == DramaDownloadStatus.paused,
    );
    return Scaffold(
      key: const ValueKey('dramas-page'),
      appBar: AppBar(
        title: const Text('离线缓存'),
        actions: [
          IconButton(
            key: const ValueKey('dramas-pause-all'),
            tooltip: '暂停全部下载',
            onPressed: !hasActiveTasks
                ? null
                : () => _downloader.pauseAll(),
            icon: const Icon(Icons.pause_circle_outline),
          ),
          IconButton(
            key: const ValueKey('dramas-resume-all'),
            tooltip: '继续全部下载',
            onPressed: !hasPausedTasks
                ? null
                : () => _downloader.resumeAll(),
            icon: const Icon(Icons.play_circle_outline),
          ),
          IconButton(
            key: const ValueKey('dramas-clear-all'),
            tooltip: '清空全部缓存',
            onPressed: _dramas.isEmpty ? null : _clearAll,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  TextButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            )
          : _dramas.isEmpty && tasks.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.movie_filter_outlined,
                        size: 32,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '暂无离线缓存',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '播放页「更多 → 离线缓存」选择想下载的集；'
                      '下载的内容不会被自动清理。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      width: 0.6,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.movie_outlined,
                          color: Theme.of(context).colorScheme.primary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '已缓存 ${_dramas.length} 部 · 共 $episodeCount 集',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '占用空间：${formatCacheBytes(bytes)} · 加密离线播放',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                for (final task in tasks)
                  if (!_dramas.any(
                    (item) =>
                        item.drama.id == task.seriesId &&
                        item.episodes.any(
                          (episode) => episode.itemId == task.itemId,
                        ),
                  ))
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        key: ValueKey('download-task-${task.itemId}'),
                        leading: const Icon(Icons.downloading),
                        title: Text(
                          task.title.isEmpty ? task.itemId : task.title,
                        ),
                        subtitle: task.progress != null
                            ? LinearProgressIndicator(value: task.progress)
                            : null,
                        trailing: Text(_taskLabel(task.status)),
                      ),
                    ),
                for (final item in _dramas)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    key: ValueKey('drama-card-${item.drama.id}'),
                    child: ExpansionTile(
                      leading: const Icon(Icons.movie_outlined),
                      title: Text(item.drama.title),
                      subtitle: Text(
                        '${item.episodes.length} 集 · ${formatCacheBytes(item.bytes)}',
                      ),
                      trailing: IconButton(
                        tooltip: '删除《${item.drama.title}》缓存',
                        onPressed: () => _deleteDrama(item),
                        icon: const Icon(Icons.delete_outline),
                      ),
                      children: [
                        for (final episode in item.episodes)
                          ListTile(
                            key: ValueKey(
                              'drama-episode-${episode.itemId}',
                            ),
                            dense: true,
                            title: Text(
                              '第 ${episode.index + 1} 集'
                              '${episode.title.isEmpty ? '' : ' · ${episode.title}'}',
                            ),
                            subtitle: Text(
                              '${formatCacheBytes(episode.bytes)} · '
                              '${episode.variantName.isEmpty ? '默认画质' : episode.variantName}',
                            ),
                            trailing: IconButton(
                              key: ValueKey(
                                'drama-episode-delete-${episode.itemId}',
                              ),
                              tooltip: '删除该集',
                              onPressed: () => _deleteEpisode(episode),
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 20,
                              ),
                            ),
                          ),
                        for (final task in _downloader.tasksFor(item.drama.id))
                          if (!item.episodes.any(
                            (episode) => episode.itemId == task.itemId,
                          ))
                            ListTile(
                              key: ValueKey(
                                'drama-task-${task.itemId}',
                              ),
                              dense: true,
                              title: Text(task.title),
                              subtitle: task.progress != null
                                  ? LinearProgressIndicator(
                                      value: task.progress,
                                    )
                                  : null,
                              trailing: _taskTrailing(task),
                            ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget? _taskTrailing(DramaDownloadTask task) {
    switch (task.status) {
      case DramaDownloadStatus.completed:
        return null;
      case DramaDownloadStatus.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('失败', style: TextStyle(color: Colors.red.shade700)),
            IconButton(
              tooltip: '重试',
              onPressed: () => _downloader.resume(task.itemId),
              icon: const Icon(Icons.refresh),
            ),
          ],
        );
      case DramaDownloadStatus.paused:
        return IconButton(
          tooltip: '继续下载',
          onPressed: () => _downloader.resume(task.itemId),
          icon: const Icon(Icons.play_arrow),
        );
      case DramaDownloadStatus.downloading:
      case DramaDownloadStatus.waiting:
        return Text(_taskLabel(task.status));
    }
  }

  String _taskLabel(DramaDownloadStatus status) => switch (status) {
    DramaDownloadStatus.waiting => '排队中',
    DramaDownloadStatus.downloading => '下载中',
    DramaDownloadStatus.paused => '已暂停',
    DramaDownloadStatus.completed => '已完成',
    DramaDownloadStatus.failed => '失败',
  };
}
