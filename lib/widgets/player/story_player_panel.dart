import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../../models/media_item.dart';

/// 官方选集格子（`bbw.xml` + `hj3/r0.java` + colors.xml）：
/// 当前集 文字 `@color/aok`=#FFFA6725、底 `@color/aom`=#1AFA6725、粗体；
/// 已看 文字 `skin_color_gray_40_light`=#66000000；普通 `skin_color_black_light`
/// =#FF000000；格子底 `@drawable/o4`=#08000000、圆角 8dp；播放中
/// `video_playing_orange.json` 12×12dp 挂右上角（margin 4，loop）。
const _currentText = Color(0xFFFA6725);
const _currentBg = Color(0x1AFA6725);
const _watchedText = Color(0x66000000);
const _normalText = Color(0xFF000000);
const _tileBg = Color(0x08000000);

/// 官方长剧分页（`gj3/o.java:731` `setGroupByCount(30)`）：每 30 集一组
/// 「1-30/31-60/…」，>30 集出现、滚动联动，≤30 隐藏。
const _pageSize = 30;
const _columns = 6;

class StoryPlayerPanel extends StatefulWidget {
  final ScrollController scrollController;
  final List<Chapter> episodes;
  final int currentIndex;
  final int? playingIndex;
  final bool playing;

  /// 已看集（灰字 #66000000）。官方取观看历史（`hj3/r0.java:224-235`），
  /// 本仓库由宿主给：续播点之前的集 + 本次会话播过的集。
  final Set<int> watched;
  final ValueChanged<int> onSelectEpisode;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final GestureDragCancelCallback onDragCancel;

  const StoryPlayerPanel({
    super.key,
    required this.scrollController,
    required this.episodes,
    required this.currentIndex,
    required this.playingIndex,
    this.playing = false,
    this.watched = const <int>{},
    required this.onSelectEpisode,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  @override
  State<StoryPlayerPanel> createState() => _StoryPlayerPanelState();
}

class _StoryPlayerPanelState extends State<StoryPlayerPanel> {
  late int _page;
  bool _needsLocate = true;
  bool _locating = false;
  double _tileHeight = 52;

  /// 最近一次居中定位用的视口高：展开动画期间逐帧对比，变了就重定位。
  double? _lastLocateViewport;

  @override
  void initState() {
    super.initState();
    _page = _pageOf(widget.currentIndex);
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(StoryPlayerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.episodes, widget.episodes)) _needsLocate = true;
    if (oldWidget.currentIndex != widget.currentIndex) _needsLocate = true;
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  int _pageOf(int index) => (index ~/ _pageSize).clamp(0, _lastPage);

  int get _lastPage => math.max(0, (widget.episodes.length - 1) ~/ _pageSize);

  /// 官方打开面板时自动滚动并把当前集**居中定位**（`gj3/o.java:237-272,
  /// 1116-1186`，偏移=视口高/2−半格−12dp）；长剧同时切到所在分页。
  void _locateEpisode() {
    if (!_needsLocate) return;
    _needsLocate = false;
    // build 期间不允许 setState；分页条在下一帧读到新值。
    _page = _pageOf(widget.currentIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.scrollController.hasClients ||
          !widget.scrollController.position.hasContentDimensions ||
          widget.scrollController.position.viewportDimension <= 0) {
        _needsLocate = true;
        return;
      }
      _centerCurrentEpisode();
      _relocateWhileSheetExpands();
    });
  }

  /// 把当前集滚到视口竖直居中（真机验证：面板有 200ms 展开动画，首帧
  /// viewportDimension 是展开中的瞬时小值，展开完成后当前集被顶到列表
  /// 顶部——定位必须跟随视口长大重算）。
  void _centerCurrentEpisode() {
    final position = widget.scrollController.position;
    final row = widget.currentIndex ~/ _columns;
    final stride = _tileHeight + 8;
    final cellTop = 4 + row * stride;
    _lastLocateViewport = position.viewportDimension;
    _locating = true;
    widget.scrollController.jumpTo(
      (cellTop - position.viewportDimension / 2 + _tileHeight / 2 - 12)
          .clamp(0.0, position.maxScrollExtent),
    );
    _locating = false;
  }

  /// 展开期间视口每帧都在变：逐帧用新视口重定位，视口高稳定（动画结束）
  /// 即停。用户滚动不改视口高，不会误触发。
  void _relocateWhileSheetExpands() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.scrollController.hasClients ||
          !widget.scrollController.position.hasContentDimensions ||
          widget.scrollController.position.viewportDimension <= 0) {
        return;
      }
      final viewport = widget.scrollController.position.viewportDimension;
      final located = _lastLocateViewport;
      if (located != null && (viewport - located).abs() <= 0.5) return;
      _centerCurrentEpisode();
      _relocateWhileSheetExpands();
    });
  }

  /// 官方 tab 条滚动联动：可视区顶部所在行换页时更新选中的「1-30」段
  /// （`view/f.java:669-739`）。打开定位（jumpTo）不联动——官方打开时
  /// 选中页就是当前集所在页，用户滚动后才跟随可视区。
  void _onScroll() {
    if (_locating || !mounted || !widget.scrollController.hasClients) return;
    final position = widget.scrollController.position;
    if (!position.hasContentDimensions || position.viewportDimension <= 0) {
      return;
    }
    final topRow = (position.pixels / (_tileHeight + 8)).floor();
    final page = (topRow * _columns) ~/ _pageSize;
    if (page != _page && page >= 0 && page <= _lastPage) {
      setState(() => _page = page);
    }
  }

  void _jumpToPage(int page) {
    setState(() => _page = page);
    if (!widget.scrollController.hasClients ||
        !widget.scrollController.position.hasContentDimensions) {
      return;
    }
    final position = widget.scrollController.position;
    final row = (page * _pageSize) ~/ _columns;
    widget.scrollController.jumpTo(
      (4 + row * (_tileHeight + 8)).clamp(0.0, position.maxScrollExtent),
    );
  }

  void _select(int index) => widget.onSelectEpisode(index);

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    final tabHeight = math.max(40.0, scale.scale(14) + 22);
    final showPaging = widget.episodes.length > _pageSize;
    final headerHeight = 12 + tabHeight + (showPaging ? 36 : 0);
    // A sheet-height change only needs layout. Keep the existing header and
    // lazy list children; state/data/text-scale changes create a fresh build.
    Widget? contents;
    return Theme(
      data: ThemeData.light(useMaterial3: true),
      child: Material(
        key: const ValueKey('story-panel'),
        color: Colors.white,
        // 官方 `skin_bg_short_series_episode_dialog`：顶部圆角 16dp。
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _tileHeight = math.max(
              44.0,
              ((constraints.maxWidth - 24 - (_columns - 1) * 8) / _columns) *
                  52 /
                  53,
            );
            _locateEpisode();
            // While the sheet closes, clip the fixed header instead of
            // squeezing its controls into a zero-height Column.
            return OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: math.max(headerHeight, constraints.maxHeight),
              maxHeight: math.max(headerHeight, constraints.maxHeight),
              child: contents ??= Column(
                children: [
                  GestureDetector(
                    key: const ValueKey('story-panel-drag'),
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragStart: widget.onDragStart,
                    onVerticalDragUpdate: widget.onDragUpdate,
                    onVerticalDragEnd: widget.onDragEnd,
                    onVerticalDragCancel: widget.onDragCancel,
                    child: Column(
                      children: [
                        SizedBox(
                          height: 12,
                          child: Center(
                            child: Container(
                              // 官方 grabber：36×4dp、`@drawable/yt` 圆角 2、
                              // `#1A000000`（`aa8.xml:6`）。
                              width: 36,
                              height: 4,
                              decoration: BoxDecoration(
                                color: const Color(0x1A000000),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: tabHeight,
                          child: Row(
                            children: [
                              // 官方单 tab「选集」：14sp 粗体 `#FF1B1B1B`、
                              // padding 20/13、无下划线指示器（`hj3/p.java:97-124`）。
                              // 「简介」tab 仅有关联剧才出现（本仓库无数据）。
                              Padding(
                                padding: const EdgeInsets.only(left: 20),
                                child: Text(
                                  '选集',
                                  style: TextStyle(
                                    fontSize: 14,
                                    height: 1.0,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF1B1B1B),
                                    leadingDistribution:
                                        TextLeadingDistribution.even,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (showPaging) _pagingStrip(),
                  Expanded(child: _episodes()),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _pagingStrip() => SizedBox(
    key: const ValueKey('story-episode-pages'),
    height: 36,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        for (var page = 0; page <= _lastPage; page++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _jumpToPage(page),
              child: Center(
                child: Text(
                  '${page * _pageSize + 1}-'
                  '${math.min((page + 1) * _pageSize, widget.episodes.length)}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: page == _page
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: page == _page
                        ? const Color(0xFF1B1B1B)
                        : const Color(0x66000000),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _episodes() {
    if (widget.episodes.isEmpty) {
      return const Center(
        key: ValueKey('story-episodes'),
        child: Text('暂无剧集', style: TextStyle(color: Color(0xFF9499A0))),
      );
    }
    return CustomScrollView(
      key: const ValueKey('story-episodes'),
      controller: widget.scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          sliver: SliverGrid(
            key: const ValueKey('story-episode-grid'),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _columns,
              mainAxisExtent: _tileHeight,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, position) => _episodeTile(position),
              childCount: widget.episodes.length,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: SizedBox(height: 16 + MediaQuery.paddingOf(context).bottom),
        ),
      ],
    );
  }

  Widget _episodeTile(int index) {
    final active = index == (widget.playingIndex ?? widget.currentIndex);
    final watched = !active && widget.watched.contains(index);
    return Semantics(
      key: ValueKey('story-episode-$index'),
      label: '第 ${index + 1} 集',
      value: active ? (widget.playing ? '正在播放' : '当前剧集') : null,
      button: true,
      selected: active,
      excludeSemantics: true,
      onTap: () => _select(index),
      child: Material(
        color: active ? _currentBg : _tileBg,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _select(index),
          child: Stack(
            children: [
              Center(
                child: Text(
                  '${index + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: active ? FontWeight.bold : FontWeight.normal,
                    color: active
                        ? _currentText
                        : watched
                        ? _watchedText
                        : _normalText,
                  ),
                ),
              ),
              if (active)
                Positioned(
                  top: 4,
                  right: 4,
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: Lottie.asset(
                      'assets/lottie/video_playing_orange.json',
                      animate: widget.playing,
                      repeat: true,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
