import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/chapter_cache_store.dart' show formatCacheBytes;
import '../../services/drama_download_store.dart';
import '../../services/drama_downloader.dart';
import '../home/home_design.dart';
import '../settings/settings_widgets.dart';
import '../shelf/shelf_design.dart';

/// 下载状态的中文标签（管理页与任务行共用）。
String dramaTaskLabel(DramaDownloadStatus status) => switch (status) {
  DramaDownloadStatus.waiting => '排队中',
  DramaDownloadStatus.downloading => '下载中',
  DramaDownloadStatus.paused => '已暂停',
  DramaDownloadStatus.completed => '已完成',
  DramaDownloadStatus.failed => '失败',
};

Color _deleteColor(HomePalette palette) =>
    palette.eink ? Colors.black : ShelfTokens.deleteRed;

Widget _rowDivider(HomePalette palette) => Divider(
  height: 1,
  thickness: 0.6,
  indent: 16,
  endIndent: 16,
  color: palette.line,
);

/// 任务行尾：进行中给文字状态，失败给红色「失败」+ 重试，暂停给继续。
class TaskTrailing extends StatelessWidget {
  const TaskTrailing({super.key, required this.task, required this.onRetry});

  final DramaDownloadTask task;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return switch (task.status) {
      DramaDownloadStatus.completed => const SizedBox.shrink(),
      DramaDownloadStatus.failed => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('失败', style: TextStyle(color: _deleteColor(palette))),
          IconButton(
            tooltip: '重试',
            onPressed: onRetry,
            icon: Icon(LucideIcons.rotate_cw, size: 20, color: palette.ink),
          ),
        ],
      ),
      DramaDownloadStatus.paused => IconButton(
        tooltip: '继续下载',
        onPressed: onRetry,
        icon: Icon(LucideIcons.play, size: 20, color: palette.ink),
      ),
      DramaDownloadStatus.downloading || DramaDownloadStatus.waiting => Text(
        dramaTaskLabel(task.status),
        style: TextStyle(fontSize: 13, color: palette.muted),
      ),
    };
  }
}

Widget _progressBar(HomePalette palette, double? value) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
  child: ClipRRect(
    borderRadius: BorderRadius.circular(2),
    child: LinearProgressIndicator(
      value: value,
      minHeight: 3,
      color: palette.accentText,
      backgroundColor: palette.line,
    ),
  ),
);

/// 尚未归入剧集卡片的下载任务（目录还没落盘时单独成卡）。
class DownloadTaskCard extends StatelessWidget {
  const DownloadTaskCard({
    super.key,
    required this.task,
    required this.onRetry,
  });

  final DramaDownloadTask task;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SettingsGroupCard(
        showDividers: false,
        children: [
          SettingsRow(
            key: ValueKey('download-task-${task.itemId}'),
            icon: LucideIcons.download,
            iconTile: true,
            title: task.title.isEmpty ? task.itemId : task.title,
            trailing: TaskTrailing(task: task, onRetry: onRetry),
          ),
          if (task.progress case final progress?)
            _progressBar(palette, progress),
        ],
      ),
    );
  }
}

/// 按剧聚合的缓存卡片：头部统计 + 展开后的集级明细与在途任务。
class CachedDramaCard extends StatefulWidget {
  const CachedDramaCard({
    super.key,
    required this.summary,
    required this.tasks,
    required this.onDeleteDrama,
    required this.onDeleteEpisode,
    required this.onRetry,
  });

  final CachedDramaSummary summary;

  /// 属于本剧、但还没有落成 [CachedEpisode] 的在途任务。
  final List<DramaDownloadTask> tasks;
  final VoidCallback onDeleteDrama;
  final ValueChanged<CachedEpisode> onDeleteEpisode;
  final ValueChanged<DramaDownloadTask> onRetry;

  @override
  State<CachedDramaCard> createState() => _CachedDramaCardState();
}

class _CachedDramaCardState extends State<CachedDramaCard> {
  bool _expanded = false;

  /// 这一集在本剧里的位置（0 起）。目录顺序才是权威的；记录里的 index
  /// 只在目录里找不到条目时兜底（理论上不会发生）。
  int _position(CachedEpisode episode) {
    final position = widget.summary.drama.episodes.indexWhere(
      (entry) => entry.itemId == episode.itemId,
    );
    return position >= 0 ? position : episode.index;
  }

  Widget _episodeRow(CachedEpisode episode, HomePalette palette) {
    return SettingsRow(
      key: ValueKey('drama-episode-${episode.itemId}'),
      icon: LucideIcons.play,
      title:
          '第 ${_position(episode) + 1} 集'
          '${episode.title.isEmpty ? '' : ' · ${episode.title}'}',
      subtitle:
          '${formatCacheBytes(episode.bytes)} · '
          '${episode.variantName.isEmpty ? '默认画质' : episode.variantName}',
      trailing: IconButton(
        key: ValueKey('drama-episode-delete-${episode.itemId}'),
        tooltip: '删除该集',
        onPressed: () => widget.onDeleteEpisode(episode),
        icon: Icon(LucideIcons.trash, size: 20, color: _deleteColor(palette)),
      ),
    );
  }

  Widget _taskRow(DramaDownloadTask task, HomePalette palette) {
    return Column(
      key: ValueKey('drama-task-${task.itemId}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsRow(
          icon: LucideIcons.download,
          title: task.title,
          trailing: TaskTrailing(
            task: task,
            onRetry: () => widget.onRetry(task),
          ),
        ),
        if (task.progress case final progress?) _progressBar(palette, progress),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final summary = widget.summary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SettingsGroupCard(
        showDividers: false,
        children: [
          SettingsRow(
            icon: LucideIcons.clapperboard,
            iconTile: true,
            title: summary.drama.title,
            subtitle:
                '${summary.episodes.length} 集'
                ' · ${formatCacheBytes(summary.bytes)}',
            onTap: () => setState(() => _expanded = !_expanded),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '删除《${summary.drama.title}》缓存',
                  onPressed: widget.onDeleteDrama,
                  icon: Icon(
                    LucideIcons.trash,
                    size: 20,
                    color: _deleteColor(palette),
                  ),
                ),
                Icon(
                  _expanded ? LucideIcons.chevron_up : LucideIcons.chevron_down,
                  size: 18,
                  color: palette.muted,
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            for (final episode in summary.episodes) ...[
              _rowDivider(palette),
              _episodeRow(episode, palette),
            ],
            for (final task in widget.tasks) ...[
              _rowDivider(palette),
              _taskRow(task, palette),
            ],
          ],
        ],
      ),
    );
  }
}
