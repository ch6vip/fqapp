import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart' show SeriesDetail, SeriesRelateBook;
import '../models/related_series.dart';
import '../widgets/player/related_series_sheet.dart';
import '../services/api_client.dart';
import '../services/backend_transport.dart';
import '../services/library_store.dart';
import '../services/player_history.dart';
import '../services/shelf_store.dart';
import '../services/watched_episodes.dart' show WatchedEpisodes, watchedIndexes;
import '../widgets/home/home_design.dart';
import '../widgets/player/playlet_comment_panel.dart';
import '../widgets/player/story_player_panel.dart' show SeriesStatus;
import '../widgets/series_detail/series_detail_book.dart';
import '../widgets/series_detail/series_detail_episodes.dart';
import '../widgets/series_detail/series_detail_hero.dart';
import '../widgets/series_detail/series_detail_info.dart';
import '../widgets/series_detail/series_detail_reviews.dart';
import '../widgets/series_detail/series_detail_tabs.dart';
import '../widgets/series_detail/series_detail_theme.dart';
import '../widgets/series_detail/series_detail_top_bar.dart';
import 'detail_page.dart' show openBookDetail;
import 'player_page.dart' show PlayerPage;

/// 短剧详情：跟随应用主题（浅色 / 深色 / 墨水屏 / OLED），首屏依次是
/// 头部、播放 / 收藏、选集，再往下才是简介、剧评与原著小说。
///
/// 剧集主色只留作顶栏与头部后面的一条淡色带；详情接口返回空不算失败，
/// 目录失败只在选集区块内联重试。
/// Note: 入口数据复用与占位裁撤见
/// .agents/notes/implemented/bug-fix/2026-09-30-series-detail-usability.md
class SeriesDetailPage extends StatefulWidget {
  const SeriesDetailPage({
    super.key,
    required this.seriesId,
    this.kind = 'video',
    this.title = '',
    this.cover = '',
    this.episodes = const [],
    this.startIndex,
    this.initialDetail,
    this.hasPlaybackProgress = false,
    this.historyStore,
    this.onPlaySelection,
    this.watchedIds = const <String>{},
    this.seriesLoader,
    this.commentLoader,
    this.directoryLoader,
    this.onPlayEpisode,
    this.onOpenRelatedSeries,
  });

  final String seriesId;
  final String kind;
  final ValueChanged<RelatedSeries>? onOpenRelatedSeries;

  /// 详情接口回来前的兜底标题/封面（宿主播放页已拉过一次 seriesDetail）。
  final String title;
  final String cover;

  /// 剧集目录：宿主已有，避免二次拉目录。
  final List<Chapter> episodes;

  /// 宿主当前集优先；null 时从本地历史恢复。
  final int? startIndex;
  final SeriesDetail? initialDetail;
  final bool hasPlaybackProgress;
  final ReaderStore? historyStore;

  /// 携带已加载目录，feed 开播放器时无需再次请求。
  final void Function(int index, List<Chapter> episodes, SeriesDetail detail)?
  onPlaySelection;

  /// 已看集 id（映射成下标给选集格子灰字）。
  final Set<String> watchedIds;

  /// 测试注入缝；默认走 `ApiClient.seriesDetail`。
  final Future<SeriesDetail> Function(String seriesId)? seriesLoader;

  /// 测试注入缝；默认走 `ApiClient.playletComments`。
  final Future<PlayletCommentPage> Function(String seriesId)? commentLoader;

  /// 目录加载器（测试缝）。宿主（播放页）已拉过目录时直接传 [episodes]；
  /// 从 feed 等没有目录的入口进来时，页面自己拉（官方详情页也持有目录），
  /// 缺省走 `ApiClient.directoryChapters(id, tab: '短剧')`。
  final Future<List<List<Chapter>>> Function(String seriesId)? directoryLoader;

  /// 点选集格或播放钮的目标行为。默认推整页播放器；宿主播放页打开
  /// 详情时传入「关闭详情 + 切集」，不叠第二个播放器。
  final ValueChanged<int>? onPlayEpisode;

  @override
  State<SeriesDetailPage> createState() => _SeriesDetailPageState();
}

class _SeriesDetailPageState extends State<SeriesDetailPage> {
  double get _tabsHeight =>
      40 * (MediaQuery.textScalerOf(context).scale(16) / 16).clamp(1.0, 2.0);

  /// 选集一段 50 集（1–50 / 51–80 …）。
  static const _pageSize = 50;

  /// 顶部色带淡出到画布的高度。
  static const _bandHeight = 240.0;

  /// 滚过这段距离后顶栏浮现剧名（VideoCommonTitleBar 初始 gone）。
  static const _topBarRevealOffset = 150.0;

  SeriesDetail _detail = SeriesDetail.empty;
  bool _detailDone = false;
  bool _detailFailed = false;
  bool _episodesFailed = false;
  bool _commentsLoading = true;
  bool _commentsFailed = false;
  bool _historyDone = false;
  bool _hasProgress = false;
  bool _shelfBusy = false;
  int _currentIndex = 0;
  Map<String, dynamic>? _savedHistory;
  Set<String> _watchedIds = {};
  Set<int> _watched = {};
  final BackendRequest _requests = BackendRequest();
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _episodeKey = GlobalKey();

  /// feed 等入口没带目录时自拉的剧集（宿主传了 [SeriesDetailPage.episodes]
  /// 就以宿主为准，不重复请求）。
  List<Chapter> _loadedEpisodes = const [];
  bool _episodesDone = false;
  PlayletCommentPage? _comments;
  int _tab = 0;
  bool _userScrolling = false;
  bool _scrolled = false;

  /// tab 行（SliverPersistentHeader）是否已吸顶：吸顶后内容会从下面穿过，
  /// 需要不透明背景；未吸顶时保持透明融入背景色带。
  bool _tabsPinned = false;

  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _sectionKeys = [GlobalKey(), GlobalKey(), GlobalKey()];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.startIndex ?? 0;
    _hasProgress = widget.hasPlaybackProgress || _currentIndex > 0;
    _watchedIds = {...widget.watchedIds};
    _syncEpisodes();
    final initial = widget.initialDetail;
    if (initial != null && !initial.isEmpty) {
      _detail = initial;
      _detailDone = true;
    }
    unawaited(_loadHistory());
    if (!_detailDone) unawaited(_loadDetail());
    unawaited(_loadEpisodes());
    unawaited(_loadComments());
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _requests.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<T> _request<T>(Future<T> Function() body) =>
      ApiClient.instance.withCancellation(_requests, body);

  Future<void> _loadHistory() async {
    try {
      final store = widget.historyStore ?? LibraryStore.instance;
      final values = await Future.wait<Object?>([
        PlayerHistory(store).load(widget.seriesId),
        WatchedEpisodes(store).ids(widget.seriesId),
      ]);
      if (!mounted) return;
      _savedHistory = values[0] as Map<String, dynamic>?;
      _watchedIds.addAll(values[1] as Set<String>);
    } catch (_) {
      // 本地历史不可用不阻断目录和播放。
    }
    if (!mounted) return;
    setState(() {
      _historyDone = true;
      _syncEpisodes();
    });
  }

  void _syncEpisodes() {
    if (_episodes.isNotEmpty) {
      if (widget.startIndex == null) {
        final savedIndex = resumeEpisodeIndex(_savedHistory, _episodes);
        _currentIndex = savedIndex ?? 0;
        _hasProgress = savedIndex != null;
      }
      _currentIndex = _currentIndex.clamp(0, _episodes.length - 1);
    }
    _watched = watchedIndexes(_watchedIds, _episodes);
  }

  Future<void> _loadDetail() async {
    setState(() {
      _detailDone = false;
      _detailFailed = false;
    });
    try {
      final detail = await _request(
        () =>
            widget.seriesLoader?.call(widget.seriesId) ??
            ApiClient.instance.seriesDetail(widget.seriesId, strict: true),
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _detailDone = true;
        // 空回包不是失败：目录能给的照常渲染，简介 / 演员自然为空。
        _detailFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _detailDone = true;
        _detailFailed = true;
      });
    }
  }

  Future<void> _loadComments() async {
    setState(() {
      _commentsLoading = true;
      _commentsFailed = false;
    });
    try {
      final page = await _request(
        () =>
            widget.commentLoader?.call(widget.seriesId) ??
            ApiClient.instance.playletComments(widget.seriesId, count: 10),
      );
      if (!mounted) return;
      setState(() {
        _comments = page;
        _commentsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _commentsLoading = false;
        _commentsFailed = true;
      });
    }
  }

  Future<void> _loadEpisodes() async {
    if (widget.episodes.isNotEmpty || widget.seriesId.isEmpty) {
      _episodesDone = true;
      return;
    }
    setState(() {
      _episodesDone = false;
      _episodesFailed = false;
    });
    try {
      final volumes = await _request(
        () =>
            widget.directoryLoader?.call(widget.seriesId) ??
            ApiClient.instance.directoryChapters(
              widget.seriesId,
              tab: widget.kind == 'manju' ? '漫剧' : '短剧',
            ),
      );
      if (!mounted) return;
      setState(() {
        _loadedEpisodes = volumes
            .expand((volume) => volume)
            .toList(growable: false);
        _episodesDone = true;
        _syncEpisodes();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _episodesDone = true;
        _episodesFailed = true;
      });
    }
  }

  /// 生效剧集：宿主带的优先，否则用自拉的。
  List<Chapter> get _episodes =>
      widget.episodes.isNotEmpty ? widget.episodes : _loadedEpisodes;

  String get _titleText =>
      _detail.title.isNotEmpty ? _detail.title : widget.title;

  String get _coverText =>
      _detail.cover.isNotEmpty ? _detail.cover : widget.cover;

  /// 选集区头部右侧的状态文案（官方实机：`已完结 共105集 ›`）。
  String? get _episodeStatusText {
    final count = _detail.episodeCount > 0
        ? _detail.episodeCount
        : _episodes.length;
    return switch (_detail.status) {
      SeriesStatus.finished => count > 0 ? '已完结 共$count集' : '已完结',
      SeriesStatus.updating => count > 0 ? '更新至$count集' : '更新中',
      SeriesStatus.updateToday => '今日更新',
      SeriesStatus.updateStop => '断更',
      _ => null,
    };
  }

  /// 播放钮文案。目录失败不再是「重试加载」——重试在选集区块里；
  /// 这里只是不可播。
  String get _playLabel {
    if (!_episodesDone || !_historyDone) return '加载中…';
    if (_episodes.isEmpty) return _episodesFailed ? '暂不可播放' : '暂无剧集';
    if (_episodes[_currentIndex].disabled) return '暂不可播放';
    return _hasProgress ? '继续播放 · 第${_currentIndex + 1}集' : '立即播放';
  }

  bool get _playable =>
      _episodesDone &&
      _historyDone &&
      _episodes.isNotEmpty &&
      !_episodes[_currentIndex].disabled;

  // ---- 顶部色带 ----

  /// 剧集主色混合到画布后的实色带顶，null 表示不出色带（灰色系 / 墨水屏）。
  Color? _bandTop(HomePalette palette) {
    final tint = seriesBandTint(_detail.seriesColorHex, palette);
    return tint == null ? null : Color.alphaBlend(tint, palette.canvas);
  }

  void _onScroll() {
    // 官方 VideoCommonTitleBar 初始 gone，滚过头部后浮现。
    final scrolled = _scroll.hasClients && _scroll.offset > _topBarRevealOffset;
    // 统一使用滚动视口坐标，安全区和顶栏已经排除在视口之外。
    final firstTop = _offsetOf(_episodeKey);
    final tabsPinned =
        _scroll.hasClients &&
        firstTop.isFinite &&
        firstTop <= _tabsHeight + 0.5;
    // 官方 tab 与锚点区联动；滚动经过哪个区就点亮哪个 tab。
    // 选集区没有自己的 tab（官方如此），归到上方的剧评。
    var tab = 0;
    if (_userScrolling) {
      for (var i = _tabNames.length - 1; i >= 0; i--) {
        if (_offsetOf(_sectionKeys[i]) <= _tabsHeight + 8) {
          tab = i;
          break;
        }
      }
    }
    if (!mounted) return;
    if (scrolled == _scrolled &&
        tabsPinned == _tabsPinned &&
        (!_userScrolling || tab == _tab)) {
      return;
    }
    setState(() {
      _scrolled = scrolled;
      _tabsPinned = tabsPinned;
      if (_userScrolling) _tab = tab;
    });
  }

  /// 官方 tab（实机 7.0.9.32）：基本信息 / 剧评 / 原著小说 / 相关作品 /
  /// 猜你喜欢，**没有选集**。后两个本地无数据源，裁掉；原著小说仅在
  /// 确有关联书时出现。
  List<String> get _tabNames => [
    '基本信息',
    '剧评',
    ?(_detail.originalBook != null ? '原著小说' : null),
  ];

  /// 区块顶相对滚动视口顶的偏移。
  double _offsetOf(GlobalKey key) {
    final context = key.currentContext;
    if (context == null) return double.infinity;
    final box = context.findRenderObject();
    if (box is! RenderBox) return double.infinity;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox) return double.infinity;
    return box.localToGlobal(Offset.zero).dy -
        viewport.localToGlobal(Offset.zero).dy;
  }

  void _selectTab(int index) {
    setState(() => _tab = index);
    _scrollToSection(_sectionKeys[index]);
  }

  void _scrollToSection(GlobalKey key) {
    if (!_scroll.hasClients) return;
    final box = key.currentContext?.findRenderObject();
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox || viewport is! RenderBox) return;
    final top =
        box.localToGlobal(Offset.zero).dy -
        viewport.localToGlobal(Offset.zero).dy;
    final target = _scroll.offset + top - _tabsHeight - 8;
    unawaited(
      _scroll.animateTo(
        target.clamp(0.0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _play(int index) {
    if (_episodes.isEmpty) return;
    final target = index.clamp(0, _episodes.length - 1);
    if (_episodes[target].disabled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该剧集暂不可播放')));
      return;
    }
    if (widget.onPlaySelection != null) {
      widget.onPlaySelection!(target, _episodes, _detail);
      return;
    }
    if (widget.onPlayEpisode != null) {
      widget.onPlayEpisode!(target);
      return;
    }
    unawaited(
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            bookId: widget.seriesId,
            kind: widget.kind,
            title: _titleText.isEmpty ? '第${target + 1}集' : _titleText,
            cover: _coverText,
            eps: _episodes,
            startIndex: target,
            shortSeries: true,
            initialSeriesDetail: _detail,
            historyStore: widget.historyStore,
          ),
        ),
      ),
    );
  }

  void _openOriginalBook(SeriesRelateBook book) {
    unawaited(
      openBookDetail(
        context,
        MediaItem(
          id: book.id,
          title: book.title,
          cover: book.cover,
          author: '',
          badge: '原著小说',
          ep: '',
          kind: 'book',
        ),
      ),
    );
  }

  void _openAllComments() {
    unawaited(
      PlayletCommentPanel.show(
        context,
        seriesId: widget.seriesId,
        total: _comments?.totalCount ?? _detail.commentCount,
      ),
    );
  }

  Future<void> _openRelatedSeries() async {
    final entry = await RelatedSeriesSheet.show(context, widget.seriesId);
    if (!mounted || entry == null) return;
    final open = widget.onOpenRelatedSeries;
    if (open != null) {
      open(entry);
      return;
    }
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => SeriesDetailPage(
            seriesId: entry.id,
            kind: entry.kind,
            title: entry.title,
            cover: entry.cover,
            historyStore: widget.historyStore,
            seriesLoader: widget.seriesLoader,
            directoryLoader: widget.directoryLoader,
            commentLoader: widget.commentLoader,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      key: const ValueKey('series-detail-page'),
      backgroundColor: palette.canvas,
      body: Stack(
        children: [
          Positioned.fill(child: _backdrop(palette)),
          SafeArea(
            child: Column(
              children: [
                SeriesDetailTopBar(
                  title: _titleText,
                  revealed: _scrolled,
                  onBack: () => Navigator.of(context).maybePop(),
                ),
                Expanded(key: _viewportKey, child: _scrollBody(palette)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scrollBody(HomePalette palette) =>
      NotificationListener<UserScrollNotification>(
        onNotification: (notification) {
          _userScrolling = notification.direction != ScrollDirection.idle;
          return false;
        },
        child: CustomScrollView(
          key: const ValueKey('series-detail-content'),
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(child: _hero()),
            SliverPersistentHeader(
              pinned: true,
              delegate: SeriesDetailTabsDelegate(
                names: _tabNames,
                height: _tabsHeight,
                activeIndex: _tab,
                pinned: _tabsPinned,
                background: _pinnedTabsBackground(palette),
                onTap: _selectTab,
              ),
            ),
            _sliver(_episodeKey, _episodeSection()),
            _sliver(_sectionKeys[0], _introSection()),
            _sliver(_sectionKeys[1], _reviewsSection()),
            if (_detail.originalBook != null)
              _sliver(
                _sectionKeys[2],
                SeriesDetailBookSection(
                  book: _detail.originalBook!,
                  onOpen: () => _openOriginalBook(_detail.originalBook!),
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 24 + MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        ),
      );

  Widget _sliver(GlobalKey key, Widget child) => SliverToBoxAdapter(
    child: KeyedSubtree(key: key, child: child),
  );

  /// 顶部淡色带：剧集主色混合到画布，240dp 内淡出。墨水屏 / 灰色系时
  /// 整页就是画布色，没有色带。
  Widget _backdrop(HomePalette palette) {
    final top = _bandTop(palette);
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: palette.canvas)),
        if (top != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _bandHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [top, palette.canvas],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 吸顶导航垫的底：取色带在顶栏下方那一段的实色切片，吸顶后与背景
  /// 完全一致，不会出现横条。
  BoxDecoration _pinnedTabsBackground(HomePalette palette) {
    final top = _bandTop(palette);
    if (top == null) return BoxDecoration(color: palette.canvas);
    final y = MediaQuery.paddingOf(context).top + 44;
    if (y >= _bandHeight) return BoxDecoration(color: palette.canvas);
    Color slice(double offset) => Color.lerp(
      top,
      palette.canvas,
      (offset / _bandHeight).clamp(0.0, 1.0),
    )!;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [slice(y), slice(y + _tabsHeight)],
      ),
    );
  }

  Widget _hero() => ValueListenableBuilder<int>(
    valueListenable: ShelfStore.instance.listenable,
    builder: (context, _, _) => SeriesDetailHero(
      title: _titleText,
      coverUrl: ApiClient.instance.absoluteUrl(_coverText),
      statusLine: _statusLine(),
      categories: _detail.categories,
      playLabel: _playLabel,
      playEnabled: _playable,
      onPlay: () => _play(_currentIndex),
      saved: ShelfStore.instance.contains('video', widget.seriesId),
      shelfEnabled: widget.seriesId.isNotEmpty,
      shelfBusy: _shelfBusy,
      onToggleShelf: _toggleShelf,
    ),
  );

  /// 实机状态行 = `episodeLabel · 播放量`，没有追更段（官方 `bp` 布局
  /// 只有集数与播放量）。
  String _statusLine() {
    final parts = <String>[];
    if (_detail.episodeLabel.isNotEmpty) parts.add(_detail.episodeLabel);
    if (_detail.playCount > 0) parts.add('${_detail.playLabel}次播放');
    return parts.join(' · ');
  }

  Widget _episodeSection() => SeriesDetailEpisodes(
    episodes: _episodes,
    currentIndex: _currentIndex,
    watched: _watched,
    initialRange: _currentIndex ~/ _pageSize,
    pageSize: _pageSize,
    statusText: _episodes.isEmpty ? null : _episodeStatusText,
    hasRelatedSeries: _detail.hasRelatedSeries,
    onOpenRelatedSeries: _openRelatedSeries,
    loading: !_episodesDone,
    failed: _episodesFailed,
    onRetry: () => unawaited(_loadEpisodes()),
    onSelect: _play,
  );

  Widget _introSection() => SeriesDetailIntroSection(
    loading: !_detailDone,
    failed: _detailFailed,
    intro: _detail.intro,
    cast: _detail.cast,
    onRetry: () => unawaited(_loadDetail()),
  );

  Widget _reviewsSection() => SeriesDetailReviews(
    comments: _comments?.comments ?? const <PlayletComment>[],
    total: _comments?.totalCount ?? _detail.commentCount,
    loading: _commentsLoading,
    failed: _commentsFailed,
    onRetry: () => unawaited(_loadComments()),
    onShowAll: _openAllComments,
  );

  // ---- 收藏 ----

  Future<void> _toggleShelf() async {
    if (_shelfBusy) return;
    final shelf = ShelfStore.instance;
    if (!shelf.isReady) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本地收藏暂不可用，请稍后重试')));
      return;
    }
    setState(() => _shelfBusy = true);
    try {
      final added = await shelf.toggle(
        MediaItem(
          id: widget.seriesId,
          seriesId: widget.seriesId,
          title: _titleText,
          cover: _coverText,
          author: '',
          badge: '短剧',
          ep: _detail.episodeLabel,
          kind: 'video',
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(added ? '已收藏到本机书架' : '已取消收藏')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('收藏失败，请重试')));
    } finally {
      if (mounted) setState(() => _shelfBusy = false);
    }
  }
}
