// Upstream source: Wenku8_Flutter rev ebcd7f1
//   lib/offline_widgets.dart (OfflineCachePage: ArchiveFeaturePage shell,
//     ArchiveSection '本地存储', cached-size caption, empty-copy placement)
//   lib/local_maintenance_page.dart (ContentPanel/list page rhythm)
// Mechanical substitutions:
// - Drama cards (`CachedDramaCard`, `DownloadTaskCard`) stay fqapp widgets:
//   episode-level download state has no upstream counterpart and this unit is
//   scoped to the page shell. The page now supplies the archive shell, section
//   header and empty state around them.
// - Bulk actions keep their existing keys and pause/resume/clear behaviour.
//   Archive groups them in a glass menu; classic restores the original three
//   AppBar buttons. Both presentations share this page's State and downloader.
// - Loading/error retain fqapp's store semantics; archive uses the shared
//   `FeatureError` treatment and classic uses the original CacheErrorState.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/chapter_cache_store.dart' show formatCacheBytes;
import '../services/drama_download_store.dart';
import '../services/drama_downloader.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/cache/cache_list_anchor.dart';
import '../widgets/cache/cache_page_widgets.dart';
import '../widgets/cache/cached_drama_widgets.dart';
import '../widgets/home/home_design.dart';
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

  /// Owned above the shell branch so switching the presentation style moves
  /// the same content element (and expanded cards/scroll) between the classic
  /// AppBar shell and the archive header.
  final _contentKey = GlobalKey(debugLabel: 'cached-dramas-content');
  final _anchor = CacheListAnchor(debugLabel: 'cached-dramas');
  bool? _layoutClassic;
  bool? _appliedClassic;

  @override
  void initState() {
    super.initState();
    _store.changes.addListener(_reload);
    _downloader.addListener(_onTasksChanged);
    _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final classic = AppUiScope.isClassic(context);
    final previous = _layoutClassic;
    _layoutClassic = classic;
    if (previous == null || previous == classic) return;
    // The classic/archive lists use different episode-card heights. Capture
    // the first visible stable row before the shell rebuild swaps the list;
    // the post-frame restore runs after the new maxScrollExtent is known.
    final content = _contentKey.currentContext;
    if (content != null) {
      _anchor.capture(content, _anchorIds(_downloader.value));
    }
    _restoreAnchorAfterLayout();
  }

  /// The scope notifies before the page rebuilds, so the first post-frame
  /// callback can still see the old list. Wait until this page has actually
  /// built the target style, then restore into the new ScrollPosition.
  void _restoreAnchorAfterLayout() {
    final target = _layoutClassic;
    if (target == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layoutClassic != target) return;
      if (_appliedClassic != target) {
        _restoreAnchorAfterLayout();
        return;
      }
      final content = _contentKey.currentContext;
      if (content != null) _anchor.restore(content);
    });
  }

  @override
  void dispose() {
    _store.changes.removeListener(_reload);
    _anchor.dispose();
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

  /// The list padding follows the discrete style, not the animated theme
  /// tokens: a style switch must settle the new indent in the same frame as
  /// the list, or the post-frame anchor restore would land 8dp off once
  /// `featurePadding` finishes animating between 20 and 12.
  EdgeInsets _listPadding(BuildContext context) {
    final classic = AppUiScope.isClassic(context);
    final tokens = AppUiScope.presentationOf(context).tokens;
    final media = MediaQuery.of(context);
    return EdgeInsets.fromLTRB(
      tokens.pageGutter,
      media.padding.top + FrostedHeader.toolbarHeight + (classic ? 12 : 20),
      tokens.pageGutter,
      media.padding.bottom + 32,
    );
  }

  /// Stable row order shared by the anchor capture and both list builders:
  /// 目录未落盘的 loose 任务在前，按剧聚合的卡片在后。
  Iterable<String> _anchorIds(List<DramaDownloadTask> tasks) sync* {
    for (final task in _looseTasks(tasks)) {
      yield 'task:${task.itemId}';
    }
    for (final item in _dramas) {
      yield 'drama:${item.drama.id}';
    }
  }

  Widget _anchoredTask(DramaDownloadTask task, Widget child) => KeyedSubtree(
    key: _anchor.itemKey('task:${task.itemId}', title: task.title),
    child: KeyedSubtree(
      key: ValueKey('cached-drama-task-${task.itemId}'),
      child: child,
    ),
  );

  Widget _anchoredDrama(CachedDramaSummary item, Widget child) => KeyedSubtree(
    key: _anchor.itemKey('drama:${item.drama.id}', title: item.drama.title),
    child: KeyedSubtree(
      key: ValueKey('cached-drama-row-${item.drama.id}'),
      child: child,
    ),
  );

  Widget _body(
    List<DramaDownloadTask> tasks,
    ColorScheme scheme, {
    required bool classic,
  }) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (classic) {
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
        key: const ValueKey('cached-dramas-scroll'),
        controller: _anchor.scroll,
        padding: _listPadding(context),
        children: [
          CacheSummaryCard(
            icon: LucideIcons.clapperboard,
            title: '已缓存 ${_dramas.length} 部 · 共 $episodeCount 集',
            subtitle: '占用空间：${formatCacheBytes(bytes)} · 加密离线播放',
          ),
          const SizedBox(height: 12),
          for (final task in _looseTasks(tasks))
            _anchoredTask(
              task,
              DownloadTaskCard(
                task: task,
                onRetry: () => _downloader.resume(task.itemId),
              ),
            ),
          for (final item in _dramas)
            _anchoredDrama(
              item,
              CachedDramaCard(
                key: ValueKey('drama-card-${item.drama.id}'),
                summary: item,
                tasks: _pendingTasks(item),
                onDeleteDrama: () => _deleteDrama(item),
                onDeleteEpisode: _deleteEpisode,
                onRetry: (task) => _downloader.resume(task.itemId),
              ),
            ),
        ],
      );
    }
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
      controller: _anchor.scroll,
      padding: _listPadding(context),
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
            _anchoredTask(
              task,
              DownloadTaskCard(
                task: task,
                onRetry: () => _downloader.resume(task.itemId),
              ),
            ),
          for (final item in _dramas)
            _anchoredDrama(
              item,
              CachedDramaCard(
                key: ValueKey('drama-card-${item.drama.id}'),
                summary: item,
                tasks: _pendingTasks(item),
                onDeleteDrama: () => _deleteDrama(item),
                onDeleteEpisode: _deleteEpisode,
                onRetry: (task) => _downloader.resume(task.itemId),
              ),
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

  /// Classic AppBar action: direct pause/resume/clear buttons, disabled with a
  /// faded icon instead of hiding the action.
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
    final classic = AppUiScope.isClassic(context);
    _appliedClassic = classic;
    final scheme = Theme.of(context).colorScheme;
    final tasks = _downloader.value;
    final body = KeyedSubtree(
      key: _contentKey,
      child: _body(tasks, scheme, classic: classic),
    );
    if (classic) {
      final palette = HomePalette.of(context);
      final hasActiveTasks = tasks.any(
        (task) =>
            task.status == DramaDownloadStatus.downloading ||
            task.status == DramaDownloadStatus.waiting,
      );
      final hasPausedTasks = tasks.any(
        (task) => task.status == DramaDownloadStatus.paused,
      );
      return ClassicFeaturePage(
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
        child: body,
      );
    }
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
      child: body,
    );
  }
}
