// Upstream source: Wenku8_Flutter rev ebcd7f1
//   lib/offline_widgets.dart (OfflineCachePage: ArchiveFeaturePage shell,
//     ArchiveSection '本地存储', cached-size caption, empty-copy placement)
//   lib/local_maintenance_page.dart (ContentPanel/list page rhythm)
// Mechanical substitutions:
// - Drama cards (`CachedDramaCard`, `DownloadTaskCard`) stay fqapp widgets:
//   episode-level download state has no upstream counterpart and this unit is
//   scoped to the page shell. The page now supplies the archive shell, section
//   header and empty state around them.
// - Bulk actions keep their existing keys and pause/resume/clear behaviour,
//   grouped in a glass menu so the page title stays readable on phones.
// - Loading/error retain fqapp's store semantics; the error uses the shared
//   `FeatureError` treatment.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/chapter_cache_store.dart' show formatCacheBytes;
import '../services/drama_download_store.dart';
import '../services/drama_downloader.dart';
import '../widgets/cache/cached_drama_widgets.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/wenku/wenku_ui.dart';

enum _CacheAction { pause, resume, clear }

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

  Future<void> _openActions(BuildContext anchor) async {
    final action = await showGlassMenu<_CacheAction>(
      context: anchor,
      reduceMotion: MediaQuery.disableAnimationsOf(anchor),
      builder: (menu) => ListenableBuilder(
        listenable: _downloader,
        builder: (context, _) {
          final tasks = _downloader.value;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GlassMenuItem(
                key: const ValueKey('dramas-pause-all'),
                icon: CupertinoIcons.pause_circle,
                label: '暂停全部下载',
                enabled: tasks.any(
                  (task) =>
                      task.status == DramaDownloadStatus.downloading ||
                      task.status == DramaDownloadStatus.waiting,
                ),
                onPressed: () => Navigator.pop(menu, _CacheAction.pause),
              ),
              GlassMenuItem(
                key: const ValueKey('dramas-resume-all'),
                icon: CupertinoIcons.play_circle,
                label: '继续全部下载',
                order: 1,
                enabled: tasks.any(
                  (task) => task.status == DramaDownloadStatus.paused,
                ),
                onPressed: () => Navigator.pop(menu, _CacheAction.resume),
              ),
              GlassMenuItem(
                key: const ValueKey('dramas-clear-all'),
                icon: CupertinoIcons.trash,
                label: '清空全部缓存',
                order: 2,
                enabled: _dramas.isNotEmpty,
                onPressed: () => Navigator.pop(menu, _CacheAction.clear),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _CacheAction.pause:
        _downloader.pauseAll();
      case _CacheAction.resume:
        _downloader.resumeAll();
      case _CacheAction.clear:
        await _clearAll();
      case null:
        break;
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

  Widget _body(List<DramaDownloadTask> tasks, ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final error?) {
      return ListView(
        padding: featurePadding(context),
        children: [
          FeatureError(error),
          Align(
            alignment: Alignment.centerLeft,
            child: GlassTextButton(
              onPressed: _reload,
              child: const AppText('重试'),
            ),
          ),
        ],
      );
    }
    final episodeCount = _dramas.fold(
      0,
      (sum, item) => sum + item.episodes.length,
    );
    final bytes = _dramas.fold(0, (sum, item) => sum + item.bytes);
    return ListView(
      key: const ValueKey('cached-dramas-scroll'),
      padding: featurePadding(context),
      children: [
        ArchiveSection(
          title: '本地存储',
          code: 'ARCHIVE / LOCAL STORAGE',
          subtitle: _dramas.isEmpty
              ? ''
              : '已缓存 ${_dramas.length} 部 · 共 $episodeCount 集 · '
                    '${formatCacheBytes(bytes)}',
        ),
        const SizedBox(height: 14),
        AppText(
          '已下载的短剧可加密离线播放。「全部暂停/继续」只影响在途下载，'
          '清理缓存不会删除书架里的剧集。',
          style: TextStyle(
            fontSize: 13,
            height: 1.7,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
        if (_dramas.isEmpty && tasks.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: AppText(
              '暂无离线缓存',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          )
        else ...[
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
        if (_dramas.isEmpty && tasks.isEmpty) ...[
          const SizedBox(height: 10),
          AppText(
            '播放页「更多 → 离线缓存」选择想下载的集；下载的内容不会被自动清理。',
            style: TextStyle(
              fontSize: 13,
              height: 1.7,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tasks = _downloader.value;
    return ArchiveFeaturePage(
      key: const ValueKey('dramas-page'),
      title: '短剧离线缓存',
      code: 'ARCHIVE / LOCAL STORAGE',
      actions: [
        GlassMenuAnchor(
          child: Builder(
            builder: (anchor) => GlassIconButton(
              key: const ValueKey('dramas-more-actions'),
              icon: CupertinoIcons.ellipsis,
              label: '更多缓存操作',
              onPressed: () => _openActions(anchor),
            ),
          ),
        ),
      ],
      child: _body(tasks, scheme),
    );
  }
}
