import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/drama_download_store.dart';
import '../services/drama_downloader.dart';
import '../services/connectivity_status.dart';
import 'cached_dramas_page.dart';

/// 选集下载弹窗（官方 `lm3.q0`/ShortSeriesDownloadDialog 形态）：30 集一组
/// 的区间 tab + 集数网格复选 + 全选 + 下载按钮；已缓存集置灰打勾，任务
/// 态（排队/进度/失败）实时来自下载引擎。官方「离线缓存」行 = 先弹这里，
/// 管理页从弹窗头部进入。
class DramaDownloadSheet extends StatefulWidget {
  const DramaDownloadSheet({
    super.key,
    required this.seriesId,
    required this.title,
    required this.cover,
    required this.episodes,
    this.downloader,
    this.store,
    this.connectivityProbe,
  });

  final String seriesId;
  final String title;
  final String cover;
  final List<Chapter> episodes;
  final DramaDownloader? downloader;
  final DramaDownloadStore? store;

  /// 连通性探测注入点（测试用）；缺省读 connectivity_plus。
  final Future<ConnectivityView> Function()? connectivityProbe;

  static Future<void> show(
    BuildContext context, {
    required String seriesId,
    required String title,
    required String cover,
    required List<Chapter> episodes,
    DramaDownloader? downloader,
    DramaDownloadStore? store,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 200),
      reverseDuration: Duration(milliseconds: 200),
    ),
    backgroundColor: const Color(0xFFFAFAFA),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => DramaDownloadSheet(
      seriesId: seriesId,
      title: title,
      cover: cover,
      episodes: episodes,
      downloader: downloader,
      store: store,
    ),
  );

  @override
  State<DramaDownloadSheet> createState() => _DramaDownloadSheetState();
}

class _DramaDownloadSheetState extends State<DramaDownloadSheet> {
  /// 官方 `TabType.DOWNLOAD` 的区间粒度：每 30 集一组。
  static const _groupSize = 30;

  DramaDownloader get _downloader => widget.downloader ?? DramaDownloader.instance;
  DramaDownloadStore get _store => widget.store ?? HiveDramaDownloadStore.instance;

  final Set<String> _downloaded = {};
  final Set<String> _selected = {};
  int _group = 0;

  @override
  void initState() {
    super.initState();
    _downloader.addListener(_onTasksChanged);
    _store.changes.addListener(_onTasksChanged);
    _refresh();
  }

  @override
  void dispose() {
    _downloader.removeListener(_onTasksChanged);
    _store.changes.removeListener(_onTasksChanged);
    super.dispose();
  }

  void _onTasksChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    for (final episode in widget.episodes) {
      if (await _store.isDownloaded(episode.itemId)) {
        _downloaded.add(episode.itemId);
      } else {
        _downloaded.remove(episode.itemId);
        _selected.remove(episode.itemId);
      }
    }
    if (mounted) setState(() {});
  }

  List<Chapter> get _groupEpisodes {
    final start = _group * _groupSize;
    return widget.episodes
        .skip(start)
        .take(_groupSize)
        .toList(growable: false);
  }

  int get _groupCount =>
      (widget.episodes.length + _groupSize - 1) ~/ _groupSize;

  DramaDownloadTask? _taskOf(String itemId) {
    for (final task in _downloader.value) {
      if (task.itemId == itemId) return task;
    }
    return null;
  }

  Future<void> _confirmDownload() async {
    final selected = _selected
        .map((itemId) => widget.episodes.firstWhere((e) => e.itemId == itemId))
        .toList(growable: false);
    if (selected.isEmpty) return;
    final connectivity = await (widget.connectivityProbe?.call() ??
        currentConnectivity());
    if (connectivity.metered && mounted) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('流量提醒'),
          content: const Text('当前非 WI-FI 环境，下载将消耗移动流量，是否继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }
    await _downloader.enqueue(
      drama: CachedDrama(
        id: widget.seriesId,
        title: widget.title,
        cover: widget.cover,
        episodes: widget.episodes,
      ),
      episodes: selected,
    );
    if (mounted) setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    final groupEpisodes = _groupEpisodes;
    final pendingCount = widget.episodes
        .where((episode) => !_downloaded.contains(episode.itemId))
        .length;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: Column(
          key: const ValueKey('download-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '离线缓存 · ${widget.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF000000),
                      ),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('download-open-management'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const CachedDramasPage(),
                      ),
                    ),
                    child: const Text('管理'),
                  ),
                ],
              ),
            ),
            if (_groupCount > 1)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    for (var index = 0; index < _groupCount; index++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          key: ValueKey('download-group-$index'),
                          label: Text(
                            '${index * _groupSize + 1}'
                            '${_groupEnd(index) > 0 ? '-${_groupEnd(index)}' : ''}集',
                          ),
                          selected: index == _group,
                          onSelected: (_) => setState(() => _group = index),
                        ),
                      ),
                  ],
                ),
              ),
            Flexible(
              child: GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                padding: const EdgeInsets.all(16),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.4,
                children: [
                  for (final episode in groupEpisodes)
                    _episodeCell(episode),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  TextButton(
                    key: const ValueKey('download-select-all'),
                    onPressed: pendingCount == 0
                        ? null
                        : () => setState(() {
                            final groupIds = groupEpisodes
                                .map((episode) => episode.itemId)
                                .where(
                                  (itemId) => !_downloaded.contains(itemId),
                                )
                                .toSet();
                            final allSelected = groupIds.every(
                              _selected.contains,
                            );
                            if (allSelected) {
                              _selected.removeAll(groupIds);
                            } else {
                              _selected.addAll(groupIds);
                            }
                          }),
                    child: Text(
                      _groupAllSelected(groupEpisodes) ? '取消全选' : '全选',
                    ),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey('download-confirm'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFA6725),
                    ),
                    onPressed: _selected.isEmpty ? null : _confirmDownload,
                    child: Text('下载 (${_selected.length})'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _groupEnd(int index) {
    final end = (index + 1) * _groupSize;
    return end > widget.episodes.length ? widget.episodes.length : end;
  }

  bool _groupAllSelected(List<Chapter> groupEpisodes) {
    final selectable = groupEpisodes
        .map((episode) => episode.itemId)
        .where((itemId) => !_downloaded.contains(itemId))
        .toList(growable: false);
    return selectable.isNotEmpty && selectable.every(_selected.contains);
  }

  Widget _episodeCell(Chapter episode) {
    final itemId = episode.itemId;
    if (_downloaded.contains(itemId)) {
      return _cellContainer(
        key: ValueKey('download-cell-$itemId'),
        label: '已缓存',
        foreground: const Color(0x66000000),
        background: const Color(0x0F000000),
        trailing: Icons.check,
        onTap: null,
      );
    }
    final task = _taskOf(itemId);
    if (task != null) {
      final progress = task.progress;
      return _cellContainer(
        key: ValueKey('download-cell-$itemId'),
        label: switch (task.status) {
          DramaDownloadStatus.downloading =>
            progress != null ? '${(progress * 100).round()}%' : '下载中',
          DramaDownloadStatus.waiting => '排队中',
          DramaDownloadStatus.paused => '已暂停',
          DramaDownloadStatus.failed => '失败',
          DramaDownloadStatus.completed => '已缓存',
        },
        foreground: task.status == DramaDownloadStatus.failed
            ? const Color(0xFFD33918)
            : const Color(0xFFFA6725),
        background: const Color(0x14FA6725),
        onTap: task.status == DramaDownloadStatus.failed
            ? () => _downloader.resume(itemId)
            : task.status == DramaDownloadStatus.paused
            ? () => _downloader.resume(itemId)
            : null,
      );
    }
    final selected = _selected.contains(itemId);
    return _cellContainer(
      key: ValueKey('download-cell-$itemId'),
      label: '第 ${_episodeNumber(episode)} 集',
      foreground: selected ? const Color(0xFFFA6725) : const Color(0xFF000000),
      background: selected ? const Color(0x14FA6725) : const Color(0x0F000000),
      border: selected ? const Color(0xFFFA6725) : Colors.transparent,
      trailing: selected ? Icons.check : null,
      onTap: () => setState(() {
        selected ? _selected.remove(itemId) : _selected.add(itemId);
      }),
    );
  }

  int _episodeNumber(Chapter episode) =>
      widget.episodes.indexWhere((e) => e.itemId == episode.itemId) + 1;

  Widget _cellContainer({
    required Key key,
    required String label,
    required Color foreground,
    required Color background,
    Color? border,
    IconData? trailing,
    VoidCallback? onTap,
  }) => GestureDetector(
    key: key,
    onTap: onTap,
    child: Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: border == null ? null : Border.all(color: border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: foreground),
            ),
          ),
          if (trailing != null)
            Icon(trailing, size: 14, color: foreground),
        ],
      ),
    ),
  );
}
