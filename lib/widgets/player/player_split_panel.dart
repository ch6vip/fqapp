import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/book_comment.dart' show formatCount;
import '../../models/media_item.dart';
import '../home/home_design.dart';
import 'playlet_comment_panel.dart';
import 'playlet_reply_panel.dart' show PlayletReplyPageLoader;
import 'story_player_panel.dart';

/// 分屏轴向的宿主注入点。
///
/// 面板是宿主从窗口里裁出来的一条窄边：横屏分屏时它是右侧竖栏（真机
/// 900×420 下约 324×420，反而"比高还窄"），竖屏分屏时是底部横条。所以
/// 「上下 / 左右分屏」不能从面板自身宽高比反推，必须由宿主（`_buildSplit`
/// 里已经算好的 `sideBySide`）注入；只有独立挂载/测试没注入时才退回窗口
/// 比例。
class SplitPanelAxis extends InheritedWidget {
  const SplitPanelAxis({
    super.key,
    required this.sideBySide,
    required super.child,
  });

  /// true = 左右分屏（面板在右侧），false = 上下分屏（面板在下）。
  final bool sideBySide;

  static bool? maybeSideBySide(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SplitPanelAxis>()?.sideBySide;

  @override
  bool updateShouldNotify(SplitPanelAxis oldWidget) =>
      oldWidget.sideBySide != sideBySide;
}

/// 短剧分屏播放页的下半区（竖屏）或右侧栏（横屏）。
///
/// B 站式分页：面板顶部只留「简介 / 评论」两个 Tab。剧信息、简介、操作
/// 入口与选集网格都收进「简介」页，评论页因此独占除 Tab 行以外的全部
/// 高度。两页沿用现有的 [StoryPlayerPanel] 与 [PlayletCommentPanel]
/// （embedded 模式），评论页首次点开才构建，避免进页就拉评论列表。
class PlayerSplitPanel extends StatefulWidget {
  const PlayerSplitPanel({
    super.key,
    required this.seriesId,
    required this.title,
    required this.cover,
    required this.episodeLabel,
    required this.synopsis,
    required this.episodes,
    required this.currentIndex,
    required this.playingIndex,
    required this.playing,
    required this.watched,
    required this.commentCount,
    required this.onSelectEpisode,
    this.status,
    this.onOpenSeriesDetail,
    this.onOpenRelatedSeries,
    this.relateBook,
    this.onOpenRelateBook,
    this.onOpenListenMode,
    this.onOpenDownload,
    this.commentLoader,
    this.replyLoader,
    this.initialTab = 0,
    this.onCommentTotalChanged,
  });

  final String seriesId;
  final String title;
  final String cover;
  final String episodeLabel;
  final String? status;
  final String synopsis;
  final List<Chapter> episodes;
  final int currentIndex;
  final int? playingIndex;
  final bool playing;
  final Set<int> watched;
  final int commentCount;
  final ValueChanged<int> onSelectEpisode;
  final VoidCallback? onOpenSeriesDetail;
  final VoidCallback? onOpenRelatedSeries;
  final EpisodeRelateBook? relateBook;
  final VoidCallback? onOpenRelateBook;
  final VoidCallback? onOpenListenMode;
  final VoidCallback? onOpenDownload;
  final PlayletCommentPageLoader? commentLoader;
  final PlayletReplyPageLoader? replyLoader;

  /// 0 = 简介（含选集与剧信息），1 = 评论。
  final int initialTab;

  /// 评论面板拿到服务端总数（或发评论后 +1）时回传，宿主用来更新页面里的
  /// 评论入口计数。
  final ValueChanged<int>? onCommentTotalChanged;

  @override
  State<PlayerSplitPanel> createState() => _PlayerSplitPanelState();
}

class _PlayerSplitPanelState extends State<PlayerSplitPanel> {
  final _episodesScroll = ScrollController();
  late final PageController _pager;
  late int _tab;
  late bool _commentsVisited;
  bool _synopsisExpanded = false;

  /// Tab 上的「评论 N」：优先用评论面板回报的最新总数。`initialTotal` 只在
  /// 面板 initState 生效，keep-alive 之后发评论/加载分页都不会回到宿主，
  /// 不回传就会出现「Tab 写 12、列表里 13」。
  int? _commentTotal;

  int get _shownCommentTotal => _commentTotal ?? widget.commentCount;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, 1);
    _commentsVisited = _tab == 1;
    _pager = PageController(initialPage: _tab);
  }

  @override
  void dispose() {
    _pager.dispose();
    _episodesScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(PlayerSplitPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seriesId != widget.seriesId) {
      _synopsisExpanded = false;
      _commentTotal = null;
      if (_tab == 1) _commentsVisited = true;
    } else if (widget.commentCount != oldWidget.commentCount) {
      // 宿主刷新了入口计数：本地发过评论后可能已经更新，只采纳更大的值。
      final known = _commentTotal;
      if (known == null || widget.commentCount > known) {
        _commentTotal = widget.commentCount;
      }
    }
  }

  void _selectTab(int tab) {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      if (tab == 1) _commentsVisited = true;
    });
    // Tab 点击与横滑共用同一个 PageController：点选时滑过去，横滑时由
    // onPageChanged 反向同步选中态。
    if (_pager.hasClients) {
      _pager.animateToPage(
        tab,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onPageChanged(int page) {
    if (_tab == page) return;
    setState(() {
      _tab = page;
      if (page == 1) _commentsVisited = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // 轴向由宿主注入（见 [SplitPanelAxis]）；没注入时退回窗口比例。
    final injected = SplitPanelAxis.maybeSideBySide(context);
    final window = MediaQuery.sizeOf(context);
    final sideBySide = injected ?? window.width > window.height;
    // 超大字号下封面 + 标题 + 元信息 + 简介 + 操作按钮会把下半区挤到只剩
    // 一两行列表：这里按字号档收紧文案行数，并给头部一个高度上限兜底。
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    final radius = sideBySide
        ? const BorderRadius.horizontal(left: Radius.circular(14))
        : const BorderRadius.vertical(top: Radius.circular(14));
    return Theme(
      data: ThemeData(
        brightness: palette.dark ? Brightness.dark : Brightness.light,
        useMaterial3: true,
      ),
      child: Material(
        key: const ValueKey('player-split-panel'),
        color: palette.canvas,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: palette.dark
              ? BorderSide(color: palette.line.withValues(alpha: .8), width: .8)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Tab 行是面板唯一的固定层；剧信息与选集都跟着「简介」页
            // 滚动，评论页只剩 Tab 行，垂直空间比原来多出一整个头部。
            _tabs(palette),
            Divider(height: 1, color: palette.line.withValues(alpha: .7)),
            Expanded(child: _body(palette, sideBySide, largeText)),
          ],
        ),
      ),
    );
  }

  Widget _header(
    HomePalette palette,
    bool sideBySide, {
    required bool largeText,
    required double maxHeight,
  }) {
    final coverHeight = sideBySide ? 64.0 : 76.0;
    final coverWidth = sideBySide ? 48.0 : 56.0;
    final meta = _meta();
    final actions = <Widget>[
      if (widget.onOpenSeriesDetail != null)
        _action('作品详情', widget.onOpenSeriesDetail, palette),
      if (widget.onOpenRelatedSeries != null)
        _action('同系列', widget.onOpenRelatedSeries, palette),
      if (widget.onOpenListenMode != null)
        _action('听剧', widget.onOpenListenMode, palette),
      if (widget.onOpenDownload != null)
        _action('下载', widget.onOpenDownload, palette),
      if (widget.relateBook != null && widget.onOpenRelateBook != null)
        _action('原著', widget.onOpenRelateBook, palette),
    ];
    final content = Padding(
      padding: EdgeInsets.fromLTRB(16, sideBySide ? 8 : 12, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(palette, coverWidth, coverHeight),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      key: const ValueKey('player-split-title'),
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onOpenSeriesDetail,
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.title.isEmpty ? '短剧' : widget.title,
                              maxLines: largeText ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: palette.ink,
                                height: 1.25,
                              ),
                            ),
                          ),
                          if (widget.onOpenSeriesDetail != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 2),
                              child: Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                                color: palette.muted,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: palette.muted),
                      ),
                    ],
                    if (widget.synopsis.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      GestureDetector(
                        key: const ValueKey('player-split-synopsis'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(
                          () => _synopsisExpanded = !_synopsisExpanded,
                        ),
                        child: Text(
                          widget.synopsis,
                          maxLines: _synopsisExpanded ? 6 : (largeText ? 1 : 2),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color: palette.body,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 2),
            Wrap(spacing: 2, runSpacing: 0, children: actions),
          ],
        ],
      ),
    );
    // 头部限高 + 内部滚动：超大字号或面板被压得很矮时，超出的操作行
    // 不会撑破这一页，下面的选集网格始终拿得到空间。
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ClipRect(
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: content,
        ),
      ),
    );
  }

  String _meta() {
    final parts = <String>[];
    if (widget.episodeLabel.isNotEmpty) parts.add(widget.episodeLabel);
    final status = widget.status;
    if (status != null &&
        status.isNotEmpty &&
        !widget.episodeLabel.contains(status)) {
      parts.add(status);
    }
    if (widget.episodes.isNotEmpty &&
        !widget.episodeLabel.contains('${widget.episodes.length}集')) {
      parts.add('全${widget.episodes.length}集');
    }
    return parts.join(' · ');
  }

  Widget _cover(HomePalette palette, double width, double height) {
    if (widget.cover.isEmpty) return _coverFallback(palette, width, height);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: widget.cover,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => _coverFallback(palette, width, height),
      ),
    );
  }

  Widget _coverFallback(HomePalette palette, double width, double height) =>
      Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: palette.dark ? palette.soft : const Color(0xFFEDEDF0),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(
          Icons.movie_creation_outlined,
          size: 22,
          color: palette.dark ? palette.muted : const Color(0xFF9499A0),
        ),
      );

  Widget _action(String label, VoidCallback? onPressed, HomePalette palette) =>
      TextButton(
        key: ValueKey('player-split-action-$label'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: palette.accentText,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 13),
        ),
        child: Text(label),
      );

  /// 顶部 Tab 行。
  ///
  /// 分栏比例最低能拖到 25%，这时面板只剩 121dp：「简介 + 评论 1.2万」的
  /// 自然宽度约 138dp，直接放 Row 会撑爆（真机 app.log 2026-10-25 两条
  /// `RenderFlex overflowed by 17 pixels`）。放不下就整条等比缩小——
  /// 既不裁文案，也不为了省地方丢掉评论计数。
  Widget _tabs(HomePalette palette) => SizedBox(
    height: 42,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        // FittedBox 用无界约束量子项，高度得自己钉住：否则标签盒不再撑满
        // 42，下划线会跟着文字一起飘到条带中间。
        height: 42,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tabButton('简介', 0, palette),
            _tabButton(
              _shownCommentTotal > 0
                  ? '评论 ${formatCount(_shownCommentTotal)}'
                  : '评论',
              1,
              palette,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _tabButton(String label, int tab, HomePalette palette) {
    final selected = _tab == tab;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        key: ValueKey('player-split-tab-$tab'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _selectTab(tab),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? palette.accentText : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? palette.ink : palette.muted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(HomePalette palette, bool sideBySide, bool largeText) {
    final comments = _commentsVisited
        ? PlayletCommentPanel(
            key: ValueKey('player-split-comments-${widget.seriesId}'),
            embedded: true,
            seriesId: widget.seriesId,
            initialTotal: _shownCommentTotal,
            loader: widget.commentLoader,
            replyLoader: widget.replyLoader,
            onTotalChanged: (total) {
              if (total <= 0 || total == _shownCommentTotal) return;
              setState(() => _commentTotal = total);
              widget.onCommentTotalChanged?.call(total);
            },
          )
        : const SizedBox.shrink();
    // 两个 Tab 用 PageView 承载：横滑切换、点 Tab 时滑过去，同时靠
    // keep-alive 保留各自的滚动位置与已加载分页。评论仍按
    // [_commentsVisited] 懒构建，但一开始横滑就先建好，滑动途中不出现
    // 空白页。
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        if (notification.depth != 0 || _commentsVisited) return false;
        final page = _pager.hasClients ? (_pager.page ?? 0) : 0;
        if (page > .02) setState(() => _commentsVisited = true);
        return false;
      },
      child: PageView(
        key: const ValueKey('player-split-pager'),
        controller: _pager,
        onPageChanged: _onPageChanged,
        children: [
          _KeepAlivePage(child: _synopsisTab(palette, sideBySide, largeText)),
          _KeepAlivePage(child: SizedBox.expand(child: comments)),
        ],
      ),
    );
  }

  /// 「简介」页：剧信息 + 选集入口 + 选集网格。剧信息与选集入口只在
  /// 这一页出现，评论页因此拿得到完整的垂直空间。
  Widget _synopsisTab(HomePalette palette, bool sideBySide, bool largeText) {
    final episodes = StoryPlayerPanel(
      key: const ValueKey('player-split-episodes'),
      embedded: true,
      columns: sideBySide ? 4 : 6,
      scrollController: _episodesScroll,
      episodes: widget.episodes,
      currentIndex: widget.currentIndex,
      playingIndex: widget.playingIndex,
      playing: widget.playing,
      watched: widget.watched,
      onSelectEpisode: widget.onSelectEpisode,
      onDragStart: (_) {},
      onDragUpdate: (_) {},
      onDragEnd: (_) {},
      onDragCancel: () {},
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // 竖屏分屏比例最低可拖到可用高度的 25%：高度不够时先压头部，
        // 头部自己滚动，选集网格至少留下 72（一行格子）。
        final headerMax = math.max(
          0.0,
          math.min(
            constraints.maxHeight * .45,
            constraints.maxHeight - _episodeBarHeight - 72,
          ),
        );
        // 连封面都放不下时收起头部：一条封面边没有信息价值，不如把
        // 空间全部留给选集；把分隔条拖回去头部自然恢复。
        final showHeader = headerMax >= 64;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader)
              _header(
                palette,
                sideBySide,
                largeText: largeText,
                maxHeight: headerMax,
              ),
            _episodeBar(palette),
            Expanded(child: episodes),
          ],
        );
      },
    );
  }

  /// 选集入口行：Tab 改叫「简介」后，选集需要在这一页里有明确标题，
  /// 否则用户会以为选集入口被删掉了。
  Widget _episodeBar(HomePalette palette) => SizedBox(
    height: _episodeBarHeight,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Row(
        children: [
          Text(
            '选集',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: palette.ink,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // 选集还没加载出来时不要把「第1/0集」摆给用户看，
              // 空态交给下面的 StoryPlayerPanel。
              _episodeProgress(),
              key: const ValueKey('player-split-episode-count'),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ),
        ],
      ),
    ),
  );

  String _episodeProgress() {
    final count = widget.episodes.length;
    if (count == 0) return '';
    final current = widget.currentIndex.clamp(0, count - 1) + 1;
    return '第$current/$count集';
  }

  /// 行高跟随字号：2x 字号下 14sp 文本约 28 高，固定 34 会溢出。
  double get _episodeBarHeight =>
      math.max(34.0, MediaQuery.textScalerOf(context).scale(14) + 18);
}

/// PageView 默认只保留视口附近的子树；两个 Tab 都有滚动位置与已加载
/// 分页，需要 keep-alive 才能在切回时原样恢复。
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
