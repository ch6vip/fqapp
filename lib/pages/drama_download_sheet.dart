import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/drama_cache_preferences.dart';
import '../services/episode_source_cache.dart';
import '../widgets/drama_group_picker.dart';
import '../services/drama_download_store.dart';
import '../services/drama_downloader.dart';
import '../services/connectivity_status.dart';
import '../widgets/home/home_design.dart';
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
    this.currentIndex = 0,
    this.qualities = const [],
    this.downloader,
    this.store,
    this.connectivityProbe,
  });

  final String seriesId;
  final String title;
  final String cover;
  final List<Chapter> episodes;

  /// 这部剧**实际可选**的清晰度（来自当前集的取流结果）。
  ///
  /// 每集到底给哪些档位只有取流接口知道：写死 1080/720/480 会让用户选了
  /// 720 结果只能下到 360（或者反过来挑到 1080），所以优先拿真实档位列表；
  /// 拿不到（还没取流过、单流）时才退回固定档位。
  final List<EpisodeVariant> qualities;

  /// 播放页当前在看第几集（0 起）。给「往后 N 集」的快捷缓存定起点，
  /// 打开面板时也直接定位到这一集所在的区间 tab。
  final int currentIndex;
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
    int currentIndex = 0,
    List<EpisodeVariant> qualities = const [],
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
    // 与听书/详情弹层同一规则：深色 / OLED 取 surface + 发丝边，
    // 否则纯黑画布上的弹层看不出上缘。
    backgroundColor: homeSheetColor(HomePalette.of(context)),
    shape: homeSheetShape(HomePalette.of(context), top: 16),
    builder: (_) => DramaDownloadSheet(
      seriesId: seriesId,
      title: title,
      cover: cover,
      episodes: episodes,
      currentIndex: currentIndex,
      qualities: qualities,
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

  DramaDownloader get _downloader =>
      widget.downloader ?? DramaDownloader.instance;
  DramaDownloadStore get _store =>
      widget.store ?? HiveDramaDownloadStore.instance;

  final Set<String> _downloaded = {};
  final Set<String> _selected = {};

  /// 当前所在的 30 集区间；默认落在正在看的那一集里。
  late int _group = widget.currentIndex ~/ _groupSize;

  /// 正在看的那一集的锚点：打开面板后把它滚进视野。
  ///
  /// 分段是 30 集一刀切的，正在看的那一集可能在段末（第 700 集在 691-720
  /// 段的倒数第五个），不滚一下用户得自己往下找。
  final _currentEpisodeKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 目录可能比播放页手里的旧（剧集上下架后集数变少），当前集算出的
    // 区间会越界；钳到最后一组，否则网格是空的。
    final lastGroup = _groupCount > 0 ? _groupCount - 1 : 0;
    if (_group > lastGroup) _group = lastGroup;
    if (_group < 0) _group = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _currentEpisodeKey.currentContext;
      if (!mounted || context == null) return;
      Scrollable.ensureVisible(context, alignment: 0.25);
    });
    unawaited(DramaCachePreferences.instance.load());
    _downloader.addListener(_onTasksChanged);
    _store.changes.addListener(_onStoreChanged);
    _refresh();
  }

  @override
  void dispose() {
    _downloader.removeListener(_onTasksChanged);
    _store.changes.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onTasksChanged() {
    if (mounted) setState(() {});
  }

  /// 管理页删集后重新核对已缓存集。
  ///
  /// `_downloaded` 只在 [initState] 里载入过一次；只 setState 不重扫的话，
  /// 删掉的集仍显示「已缓存」且点不了，全选也还按旧状态算。
  void _onStoreChanged() {
    unawaited(_refresh());
  }

  /// 重新核对哪些集已缓存。
  ///
  /// 用代号丢弃过期结果：下载完成会连续触发多次通知，较早的一次扫描可能
  /// 在新扫描之后才结束，把刚删掉的集又加回 `_downloaded`。
  int _refreshGeneration = 0;

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    final downloaded = <String>{};
    for (final episode in widget.episodes) {
      if (await _store.isDownloaded(episode.itemId)) {
        downloaded.add(episode.itemId);
      }
    }
    if (!mounted || generation != _refreshGeneration) return;
    setState(() {
      _downloaded
        ..clear()
        ..addAll(downloaded);
      _selected.removeWhere(downloaded.contains);
    });
  }

  List<Chapter> get _groupEpisodes {
    final start = _group * _groupSize;
    return widget.episodes.skip(start).take(_groupSize).toList(growable: false);
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
    final connectivity =
        await (widget.connectivityProbe?.call() ?? currentConnectivity());
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
    final height = DramaCachePreferences.instance.downloadHeight.value;
    await _downloader.enqueue(
      drama: CachedDrama(
        id: widget.seriesId,
        title: widget.title,
        cover: widget.cover,
        episodes: widget.episodes,
      ),
      episodes: selected,
      // 0 = 最高档，交给引擎在每集实际给到的档位里挑。
      maxHeight: height == 0 ? null : height,
    );
    if (mounted) setState(_selected.clear);
  }

  /// 从正在看的那一集往后选 [count] 集并直接开始下载。
  ///
  /// 小说缓存面板是「往后 20/50/100 章 + 整本」，这里按短剧的体积给了
  /// 更小的档位；不足 [count] 集时按剩余算。已经缓存好的集跳过。
  Future<void> _cacheAhead(int count) async {
    final start = widget.currentIndex + 1;
    if (start >= widget.episodes.length || count <= 0) return;
    final end = start + count > widget.episodes.length
        ? widget.episodes.length
        : start + count;
    setState(() {
      for (final episode in widget.episodes.sublist(start, end)) {
        if (_downloaded.contains(episode.itemId)) continue;
        _selected.add(episode.itemId);
      }
    });
    await _confirmDownload();
  }

  /// 标题 + 「管理」入口。
  Widget _header(HomePalette palette) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '离线缓存 · ${widget.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: palette.ink,
            ),
          ),
        ),
        TextButton(
          key: const ValueKey('download-open-management'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const CachedDramasPage()),
          ),
          child: const Text('管理'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final groupEpisodes = _groupEpisodes;
    final palette = HomePalette.of(context);
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
            _header(palette),
            if (_groupCount > 1)
              DramaGroupPicker(
                groupCount: _groupCount,
                group: _group,
                total: widget.episodes.length,
                rangeOf: (index) => (index * _groupSize + 1, _groupEnd(index)),
                onSelected: _selectGroup,
              ),
            _aheadBar(),
            _qualityBar(palette),
            _autoCacheBar(palette),
            Flexible(
              child: GridView.count(
                // 换段时换 key，让网格重建：GridView 会保留滚动位置，
                // 不重建的话切到下一段仍停在上一段的滚动高度，看上去像
                // 「第 9 集 排在 1-30 集 下面」。
                key: ValueKey('download-grid-$_group'),
                crossAxisCount: 4,
                shrinkWrap: true,
                padding: const EdgeInsets.all(16),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.4,
                children: [
                  // 集号直接用「段首 + 段内序号」算，不再对全表 indexWhere ——
                  // 1000 集时那是 30 次全表扫描，且找不到会退化成「第 0 集」。
                  for (final (index, episode) in groupEpisodes.indexed)
                    KeyedSubtree(
                      key: _group * _groupSize + index == widget.currentIndex
                          ? _currentEpisodeKey
                          : null,
                      child: _episodeCell(
                        episode,
                        palette,
                        _group * _groupSize + index + 1,
                      ),
                    ),
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

  void _selectGroup(int index) {
    if (index == _group) return;
    setState(() => _group = index);
  }

  /// 「往后 N 集」快捷缓存：起点是正在看的那一集后面，不是第 1 集。
  Widget _aheadBar() {
    final start = widget.currentIndex + 1;
    final remaining = widget.episodes.length - start;
    if (remaining <= 0) return const SizedBox.shrink();
    final counts = <int>{
      for (final count in const [3, 5, 10])
        if (remaining >= count) count,
      remaining,
    }.toList()..sort();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          for (final count in counts)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                key: ValueKey('download-ahead-$count'),
                label: Text(count == remaining ? '剩余 $count 集' : '往后 $count 集'),
                onPressed: () => unawaited(_cacheAhead(count)),
              ),
            ),
        ],
      ),
    );
  }

  /// 下载画质：每集实际可选档位由取流接口决定，所以这里给的是「上限」。
  ///
  /// 以前下载器写死取最高档，用户既看不到也选不了 —— 一集 1080P 动辄
  /// 五六十 MB，想省空间的人毫无办法。
  Widget _qualityBar(HomePalette palette) {
    final prefs = DramaCachePreferences.instance;
    final current = prefs.downloadHeight.value;
    // 横向可滚：窄屏（360dp）上四个 chip 加标签放不下一行。
    // 真实档位优先：同一高度只留一项（上游偶尔给两条同高度不同码率的流），
    // 按高度从高到低排；0 永远排最前，表示「最高」。
    final actual = <int, String>{};
    for (final variant in widget.qualities) {
      if (variant.height <= 0) continue;
      actual.putIfAbsent(
        variant.height,
        () => variant.name.isEmpty ? '${variant.height}P' : variant.name,
      );
    }
    final options = actual.isEmpty
        // 还没取流过（或上游只给单流）：只能给固定档位表达意图，
        // 真正下载时仍按「不超过上限的最高一档」去套。
        ? [
            (height: 0, label: '最高'),
            for (final height in DramaCachePreferences.presetHeights)
              if (height != 0) (height: height, label: '${height}P'),
          ]
        : [
            (height: 0, label: '最高'),
            for (final entry
                in (actual.entries.toList()
                  ..sort((a, b) => b.key.compareTo(a.key))))
              (height: entry.key, label: entry.value),
          ];
    // 选中态按「下载器实际会取的那一档」算：存的上限可能不在这部剧的档位
    // 里（上一部选了 720，这部剧只有 1080/360），只按相等比就会一个都不
    // 高亮。规则同 DramaDownloader.pickVariant：不超过上限的最高一档，
    // 没有更低的就用最低的一档。
    final offered = [
      for (final option in options)
        if (option.height > 0) option.height,
    ];
    var effective = current;
    if (current != 0 && offered.isNotEmpty && !offered.contains(current)) {
      final fits = offered.where((height) => height < current);
      effective = fits.isEmpty
          ? offered.reduce((a, b) => a < b ? a : b)
          : fits.reduce((a, b) => a > b ? a : b);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Text('画质', style: TextStyle(fontSize: 13, color: palette.muted)),
          const SizedBox(width: 10),
          for (final option in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: ValueKey('download-quality-${option.height}'),
                label: Text(option.label),
                selected: effective == option.height,
                onSelected: (_) async {
                  await prefs.setDownloadHeight(option.height);
                  if (mounted) setState(() {});
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 边看边缓存的开关与集数档位（持久化在 [DramaCachePreferences]）。
  ///
  /// 与上面的「往后 N 集」是两件事：上面的是一次性手动批量，这里是每次
  /// 播放都自动往后续存。自动缓存只在 Wi-Fi 下跑（短剧一集几十 MB）。
  Widget _autoCacheBar(HomePalette palette) {
    final prefs = DramaCachePreferences.instance;
    final enabled = prefs.ahead.value > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '边看边缓存',
                  style: TextStyle(fontSize: 14, color: palette.ink),
                ),
                Text(
                  enabled
                      ? '看到哪集就自动往后续存 ${prefs.ahead.value} 集（仅 Wi-Fi）'
                      : '已关闭，手动缓存不受影响',
                  style: TextStyle(fontSize: 11, color: palette.muted),
                ),
              ],
            ),
          ),
          if (enabled)
            for (final count in const [3, 5, 10])
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: ChoiceChip(
                  key: ValueKey('download-auto-ahead-$count'),
                  label: Text('$count'),
                  selected: prefs.ahead.value == count,
                  onSelected: (_) async {
                    await prefs.setAhead(count);
                    if (mounted) setState(() {});
                  },
                ),
              ),
          Switch(
            key: const ValueKey('download-auto-cache-switch'),
            value: enabled,
            onChanged: (value) async {
              await prefs.setAhead(
                value ? DramaCachePreferences.defaultAhead : 0,
              );
              if (mounted) setState(() {});
            },
          ),
        ],
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

  Widget _episodeCell(Chapter episode, HomePalette palette, int number) {
    final itemId = episode.itemId;
    // 未选中的格子：浅色是 6% 黑，深色 / OLED 换成字段色。
    final idleBackground = palette.dark
        ? palette.soft
        : const Color(0x0F000000);
    if (_downloaded.contains(itemId)) {
      return _cellContainer(
        key: ValueKey('download-cell-$itemId'),
        label: '已缓存',
        foreground: palette.muted,
        background: idleBackground,
        trailing: Icons.check,
        onTap: null,
      );
    }
    final task = _taskOf(itemId);
    if (task != null) {
      final progress = task.progress;
      final cell = _cellContainer(
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
      // 失败原因写进 tooltip：只显示「失败」两个字，用户既不知道原因，
      // 也不知道点一下是重试。
      final error = task.error;
      if (task.status == DramaDownloadStatus.failed && error != null) {
        return Tooltip(
          message: '$error\n点一下重试',
          triggerMode: TooltipTriggerMode.longPress,
          child: cell,
        );
      }
      return cell;
    }
    final selected = _selected.contains(itemId);
    return _cellContainer(
      key: ValueKey('download-cell-$itemId'),
      label: '第 $number 集',
      foreground: selected ? const Color(0xFFFA6725) : palette.ink,
      background: selected ? const Color(0x14FA6725) : idleBackground,
      border: selected ? const Color(0xFFFA6725) : Colors.transparent,
      trailing: selected ? Icons.check : null,
      onTap: () => setState(() {
        selected ? _selected.remove(itemId) : _selected.add(itemId);
      }),
    );
  }

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
          if (trailing != null) Icon(trailing, size: 14, color: foreground),
        ],
      ),
    ),
  );
}
