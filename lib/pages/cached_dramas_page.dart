import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/chapter_cache_store.dart' show formatCacheBytes;
import '../services/drama_download_store.dart';
import '../services/drama_downloader.dart';
import '../widgets/cache/cache_page_widgets.dart';
import '../widgets/cache/cached_drama_widgets.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_widgets.dart';

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

  Future<bool> _confirm(String title, String content) =>
      showSettingsConfirmDialog(
        context: context,
        title: title,
        message: content,
        confirmLabel: '删除',
        destructive: true,
      );

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
    if (!await _confirm('清空全部离线缓存', '所有已下载的剧集会从设备删除，联网后可重新缓存。')) {
      return;
    }
    for (final summary in _dramas) {
      await _store.removeDrama(summary.drama.id);
    }
  }

  /// 尚未落成 [CachedEpisode]、仍属于本剧的在途任务。
  List<DramaDownloadTask> _pendingTasks(CachedDramaSummary summary) => [
    for (final task in _downloader.tasksFor(summary.drama.id))
      if (!summary.episodes.any((episode) => episode.itemId == task.itemId))
        task,
  ];

  /// 未归入任何剧集卡片的任务（目录尚未落盘）。
  Iterable<DramaDownloadTask> _looseTasks(List<DramaDownloadTask> tasks) sync* {
    for (final task in tasks) {
      final covered = _dramas.any(
        (summary) =>
            summary.drama.id == task.seriesId &&
            summary.episodes.any((episode) => episode.itemId == task.itemId),
      );
      if (!covered) yield task;
    }
  }

  Widget _body(List<DramaDownloadTask> tasks) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final error?) {
      return CacheErrorState(message: error, onRetry: _reload);
    }
    if (_dramas.isEmpty && tasks.isEmpty) {
      return const CacheEmptyState(
        icon: LucideIcons.clapperboard,
        title: '暂无离线缓存',
        message: '播放页「更多 → 离线缓存」选择想下载的集；下载的内容不会被自动清理。',
      );
    }
    final episodeCount = _dramas.fold(
      0,
      (sum, item) => sum + item.episodes.length,
    );
    final bytes = _dramas.fold(0, (sum, item) => sum + item.bytes);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        CacheSummaryCard(
          icon: LucideIcons.clapperboard,
          title: '已缓存 ${_dramas.length} 部 · 共 $episodeCount 集',
          subtitle: '占用空间：${formatCacheBytes(bytes)} · 加密离线播放',
        ),
        const SizedBox(height: 12),
        for (final task in _looseTasks(tasks))
          DownloadTaskCard(
            task: task,
            onRetry: () => _downloader.resume(task.itemId),
          ),
        for (final item in _dramas)
          CachedDramaCard(
            key: ValueKey('drama-card-${item.drama.id}'),
            summary: item,
            tasks: _pendingTasks(item),
            onDeleteDrama: () => _deleteDrama(item),
            onDeleteEpisode: _deleteEpisode,
            onRetry: (task) => _downloader.resume(task.itemId),
          ),
      ],
    );
  }

  Widget _actionButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    required HomePalette palette,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(
      icon,
      color: onPressed == null
          ? palette.muted.withValues(alpha: 0.4)
          : palette.ink,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final tasks = _downloader.value;
    final hasActiveTasks = tasks.any(
      (task) =>
          task.status == DramaDownloadStatus.downloading ||
          task.status == DramaDownloadStatus.waiting,
    );
    final hasPausedTasks = tasks.any(
      (task) => task.status == DramaDownloadStatus.paused,
    );
    return SettingsScaffold(
      key: const ValueKey('dramas-page'),
      title: '短剧离线缓存',
      actions: [
        _actionButton(
          key: const ValueKey('dramas-pause-all'),
          tooltip: '暂停全部下载',
          icon: LucideIcons.circle_pause,
          onPressed: hasActiveTasks ? _downloader.pauseAll : null,
          palette: palette,
        ),
        _actionButton(
          key: const ValueKey('dramas-resume-all'),
          tooltip: '继续全部下载',
          icon: LucideIcons.circle_play,
          onPressed: hasPausedTasks ? _downloader.resumeAll : null,
          palette: palette,
        ),
        _actionButton(
          key: const ValueKey('dramas-clear-all'),
          tooltip: '清空全部缓存',
          icon: LucideIcons.trash,
          onPressed: _dramas.isEmpty ? null : _clearAll,
          palette: palette,
        ),
      ],
      body: _body(tasks),
    );
  }
}
