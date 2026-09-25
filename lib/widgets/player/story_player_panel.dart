import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
/// 官方未选中普通格文字 `skin_color_catalog_unselect_item_text_normal_dark`
/// = @color/skin_color_black_dark = **#CCFFFFFF**（不是纯黑）。
const _normalText = Color(0xCCFFFFFF);
/// 官方不可播格文字 `..._text_disable_light` = #33000000。
const _disabledText = Color(0x33000000);
/// 官方普通格底色 `skin_color_gray_03_light` = #08000000。
const _tileBg = Color(0x08000000);

/// 选集格子的官方状态（`hj3/r0.java:217-235,539-554`）。
///
/// 状态色（全部来自 APK 的 colors.xml）：
/// - 选中：底 `skin_color_catalog_select_item_bg_light`=@color/aom=#1AFA6725、
///   字 `skin_color_catalog_select_item_text_light`=@color/aok=#FFFA6725
/// - 不可播：字 `..._text_disable_light`=#33000000，点击 Toast「该选集暂时无法播放」
/// - 已看：字 `..._text_played_light`=#66000000
/// - 普通：字 `..._text_normal_dark`=@color/skin_color_black_dark=#CCFFFFFF
/// - 普通格底 `skin_color_gray_03_light`=#08000000
enum EpisodeTileState {
  normal,
  current,
  watched,
  disabled;

  static EpisodeTileState of({
    required bool current,
    required bool watched,
    required bool disabled,
  }) {
    if (current) return EpisodeTileState.current;
    if (disabled) return EpisodeTileState.disabled;
    if (watched) return EpisodeTileState.watched;
    return EpisodeTileState.normal;
  }

  Color get textColor => switch (this) {
    EpisodeTileState.current => _currentText,
    EpisodeTileState.disabled => _disabledText,
    EpisodeTileState.watched => _watchedText,
    EpisodeTileState.normal => _normalText,
  };

  Color get backgroundColor =>
      this == EpisodeTileState.current ? _currentBg : _tileBg;

  FontWeight get weight =>
      this == EpisodeTileState.current ? FontWeight.bold : FontWeight.normal;
}

/// 官方选集格子文案（`hj3/r0.java:413-419`）：预告 -> 「预告」（`epd`）、
/// 推荐流插入项 -> 「高光」（`esr`），其余是纯序号。
String episodeTileLabel({
  required int index,
  bool trailer = false,
  bool highlight = false,
}) {
  if (trailer) return '预告';
  if (highlight) return '高光';
  return '${index + 1}';
}

/// 官方「新」角标（`bbw.xml:2-10`：18x18dp 容器、圆角 6dp、底
/// `@color/aom`=#1AFA6725、内文 `@string/e0f`=「新」）。
///
/// 显示条件（`hj3/r0.java:539-554` 的 `T1`）：
/// 未选中 && 未播过 && 不在观看历史里 && `isNewlyUpdate`。
bool episodeShowsNewBadge({
  required bool current,
  required bool played,
  required bool watched,
  required bool newlyUpdate,
}) => !current && !played && !watched && newlyUpdate;

/// 官方头部的封面占位（没有封面图时用剧集首帧同款深色块）。
class _HeaderCoverFallback extends StatelessWidget {
  const _HeaderCoverFallback();

  @override
  Widget build(BuildContext context) => Container(
    width: 64,
    height: 86,
    decoration: BoxDecoration(
      color: const Color(0xFFEDEDF0),
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Icon(Icons.movie_creation_outlined, color: Color(0xFF9499A0)),
  );
}

/// 官方头部集数/状态文案（`a1.java:554-568` 的 `A2()` 与 `:2034-2056` 的 `o1()`）。
///
/// 分支顺序照搬源码：
/// 1. 电影：`电影 · 共N分钟`（N = 时长向上取整到分钟）
/// 2. 虚幻短剧（`UnrealShortPlay`）：`string/d6d`「暂未上线」
/// 3. `SeriesStatus.SeriesUpdating`：漫改用 `string/e6u`
///    「看到%s集/更新至%s集」（第一个 %s 是当前集号），否则 `string/e6s`
///    「更新至%s集」
/// 4. 其余（`SeriesEnd`/今日更新/断更都落这里）：`string/e6q`「已完结 共%s集」
///
/// 注意取证笔记里把 `d6d` 记成「未上线」的通用文案，实际源码里它只服务
/// `UnrealShortPlay` 这一支，这里按**源码**实现。
String seriesEpisodeLabel({
  required int? status,
  required int count,
  required int currentIndex,
  bool motionComic = false,
  bool unrealShortPlay = false,
  int durationSeconds = 0,
}) {
  if (unrealShortPlay) return '暂未上线';
  if (durationSeconds > 0 && count <= 1) {
    final minutes = (durationSeconds / 60).ceil();
    if (minutes > 0) return '电影 · 共$minutes分钟';
  }
  if (status == SeriesStatus.updating) {
    if (motionComic) return '看到${currentIndex + 1}集/更新至$count集';
    return '更新至$count集';
  }
  if (count > 0) return '已完结 共$count集';
  return '';
}

/// 官方 `SeriesStatus`（`com/bytedance/kmp/reading/model/SeriesStatus.java`）：
/// **0=更新中（SeriesUpdating）**、1=已完结（SeriesEnd）、3=今日更新、
/// 4=断更。注意与书库 `creation_status` 的 0=完结/1=连载语义相反。
class SeriesStatus {
  const SeriesStatus._();
  static const int updating = 0;
  static const int finished = 1;
  static const int updateToday = 3;
  static const int updateStop = 4;
}

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

  /// 头部剧信息（官方 `aa8.xml:7-15` 的 `hdp` 区块）：封面、标题、
  /// 集数/状态文案、免费角标、收藏态。官方这些字段来自剧集详情。
  final String seriesTitle;
  final String seriesCover;
  final String episodeLabel;
  final bool freeWatch;
  final bool collected;

  /// 点头部（官方 `right_icon` 箭头）与收藏。
  final VoidCallback? onOpenSeries;
  final VoidCallback? onCollect;

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
    this.seriesTitle = '',
    this.seriesCover = '',
    this.episodeLabel = '',
    this.freeWatch = false,
    this.collected = false,
    this.onOpenSeries,
    this.onCollect,
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

  /// 头部剧信息区只有在宿主给了剧名或集数文案时才出现（官方该区块常显，
  /// 本地没有数据源时不显示，避免出现空壳封面）。
  bool get _hasHeader =>
      widget.seriesTitle.isNotEmpty || widget.episodeLabel.isNotEmpty;

  double get _headerHeight => 12 + 96;

  /// 官方头部剧信息（`aa8.xml:7-15`）：封面 `hdb`、标题 `hdt`、
  /// 右箭头 `right_icon`、集数行 `he1`（免费角标 `dga` + 文案 `hdz`）、
  /// 收藏 `ddg`。免费角标：文 `@string/c3q`「免费观看」、
  /// 字色 `skin_color_green_brand_light`=#FF00AE83、
  /// 底 `skin_color_green_brand_10_light`=#1A00AE83（`colors.xml`）。
  Widget _seriesHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
    child: Row(
      children: [
        if (widget.seriesCover.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CachedNetworkImage(
              imageUrl: widget.seriesCover,
              width: 64,
              height: 86,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => const _HeaderCoverFallback(),
            ),
          )
        else
          const _HeaderCoverFallback(),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                key: const ValueKey('story-panel-series-title'),
                behavior: HitTestBehavior.opaque,
                onTap: widget.onOpenSeries,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.seriesTitle.isEmpty ? '短剧' : widget.seriesTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1B1B1B),
                        ),
                      ),
                    ),
                    if (widget.onOpenSeries != null)
                      const Padding(
                        padding: EdgeInsets.only(left: 2),
                        child: Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: Color(0xFF9499A0),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (widget.freeWatch)
                    Container(
                      key: const ValueKey('story-panel-free-badge'),
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x1A00AE83),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        '免费观看',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFF00AE83),
                        ),
                      ),
                    ),
                  if (widget.episodeLabel.isNotEmpty)
                    Text(
                      widget.episodeLabel,
                      key: const ValueKey('story-panel-episode-label'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF9499A0),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (widget.onCollect != null)
          GestureDetector(
            key: const ValueKey('story-panel-collect'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onCollect,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.collected
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    size: 22,
                    color: widget.collected
                        ? const Color(0xFFFA6725)
                        : const Color(0xFF9499A0),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.collected ? '已收藏' : '收藏',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9499A0),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );

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

  /// 官方不可播集的点击是 Toast「该选集暂时无法播放」
  /// （`hj3/r0.java:598-601`），不会切换集。
  void _select(int index) {
    if (index >= 0 &&
        index < widget.episodes.length &&
        widget.episodes[index].disabled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该选集暂时无法播放')));
      return;
    }
    widget.onSelectEpisode(index);
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    final tabHeight = math.max(40.0, scale.scale(14) + 22);
    final showPaging = widget.episodes.length > _pageSize;
    final headerHeight =
        12 + tabHeight + (showPaging ? 36 : 0) + (_hasHeader ? _headerHeight : 0);
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
                        if (_hasHeader)
                          SizedBox(
                            key: const ValueKey('story-panel-series-header'),
                            height: _headerHeight,
                            child: _seriesHeader(),
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
    final episode = widget.episodes[index];
    final active = index == (widget.playingIndex ?? widget.currentIndex);
    final state = EpisodeTileState.of(
      current: active,
      watched: widget.watched.contains(index),
      disabled: episode.disabled,
    );
    final badge = episodeShowsNewBadge(
      current: active,
      played: widget.playingIndex == index,
      watched: widget.watched.contains(index),
      newlyUpdate: episode.newlyUpdate,
    );
    return Semantics(
      key: ValueKey('story-episode-$index'),
      label: '第 ${index + 1} 集',
      value: active ? (widget.playing ? '正在播放' : '当前剧集') : null,
      button: true,
      selected: active,
      excludeSemantics: true,
      onTap: () => _select(index),
      child: Material(
        color: state.backgroundColor,
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
                  episodeTileLabel(
                    index: index,
                    trailer: episode.trailer,
                    highlight: episode.highlight,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: state.weight,
                    color: state.textColor,
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
                )
              else if (badge)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Container(
                    key: ValueKey('story-episode-new-$index'),
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _currentBg,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '新',
                      style: TextStyle(fontSize: 10, color: _currentText),
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

/// 官方横屏选集面板（真实 app 截图第二十三轮）：**右侧抽屉**——深色底、
/// 头部 ✕ + 居中「选集」、4 列格子；当前集橙底（`#B3FA6725`，暗色上的
/// 半透明橙）+ 橙字 + 右上声波，普通格白字浅底，已看淡白。竖屏的白色
/// bottom sheet（`StoryPlayerPanel`）不在此复用——两态的皮肤/列数/头部
/// 都不同，定位逻辑各自维护。
class StoryEpisodeDrawer extends StatefulWidget {
  final List<Chapter> episodes;
  final int currentIndex;
  final int? playingIndex;
  final bool playing;
  final Set<int> watched;
  final ValueChanged<int> onSelectEpisode;
  final VoidCallback onClose;

  const StoryEpisodeDrawer({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.playingIndex,
    this.playing = false,
    this.watched = const <int>{},
    required this.onSelectEpisode,
    required this.onClose,
  });

  @override
  State<StoryEpisodeDrawer> createState() => _StoryEpisodeDrawerState();
}

class _StoryEpisodeDrawerState extends State<StoryEpisodeDrawer> {
  final _scroll = ScrollController();
  double _tile = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerCurrent());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 打开时把当前集滚到视口竖直居中（竖屏面板同款语义，
  /// `gj3/o.java:237-272`；抽屉无展开动画，一帧定位即可）。格子尺寸来自
  /// 抽屉宽度，首帧未排版时顺延一帧重试。
  void _centerCurrent() {
    if (!_scroll.hasClients ||
        !_scroll.position.hasContentDimensions ||
        _tile <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _centerCurrent();
      });
      return;
    }
    final position = _scroll.position;
    final row = widget.currentIndex ~/ 4;
    _scroll.jumpTo(
      (16 + row * (_tile + 8) - position.viewportDimension / 2 + _tile / 2)
          .clamp(0.0, position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playingIndex = widget.playingIndex ?? widget.currentIndex;
    return Material(
      key: const ValueKey('story-episode-drawer'),
      color: const Color(0xFF141414),
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Stack(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      key: const ValueKey('story-drawer-close'),
                      tooltip: '关闭',
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ),
                  const Align(
                    alignment: Alignment.center,
                    child: Text(
                      '选集',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 4 列方格：宽 =（抽屉宽 − 左右 24 − 列距 3×8）/ 4。
                  _tile = (constraints.maxWidth - 24 - 24) / 4;
                  return GridView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1,
                        ),
                    itemCount: widget.episodes.length,
                    itemBuilder: (context, index) {
                      final active = index == playingIndex;
                      final watched = !active && widget.watched.contains(index);
                      return Semantics(
                        key: ValueKey('story-episode-$index'),
                        label: '第 ${index + 1} 集',
                        value: active
                            ? (widget.playing ? '正在播放' : '当前剧集')
                            : null,
                        button: true,
                        selected: active,
                        excludeSemantics: true,
                        onTap: () => widget.onSelectEpisode(index),
                        child: Material(
                          color: active
                              ? const Color(0xB3FA6725)
                              : const Color(0x26FFFFFF),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => widget.onSelectEpisode(index),
                            child: Stack(
                              children: [
                                Center(
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: active
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: active
                                          ? _currentText
                                          : watched
                                          ? const Color(0x66FFFFFF)
                                          : Colors.white,
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
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
