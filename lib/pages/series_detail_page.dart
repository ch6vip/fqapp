import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:lottie/lottie.dart';

import '../models/book_detail.dart' show formatCounter;
import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart' show SeriesDetail, SeriesRelateBook;
import '../services/api_client.dart';
import '../services/watched_episodes.dart' show watchedIndexes;
import '../widgets/player/playlet_comment_panel.dart';
import '../widgets/player/story_player_panel.dart'
    show SeriesStatus, episodeTileLabel;
import 'detail_page.dart' show DetailPage;
import 'player_page.dart' show PlayerPage;

/// 官方 V2 短剧详情页（播放页标题「剧名 >」点击的落点）。
///
/// 对齐对象：`ShortSeriesDetailActivity`（页面名 `series_detail`）→
/// `SeriesDetailFragmentV2`，根布局 `apc.xml`、头部 `a34.xml`
/// （DetailBaseInfoLayout）、底部栏 `g1.java` + `ButtonComposeBinding`
/// （Compose 双钮，默认文案「收藏 / 继续播放」）。数据请求
/// `GetVideoDetailRequest(seriesId, VideoSeriesIdType.SeriesId,
/// source=FromDetailPage)`，本地对应 `/api/v1/series/{id}`。
///
/// 2026-09-30 真机取证（官方 7.0.9.32，抽象三国第一季详情页截图）后重排：
/// 区块顺序 = 头部 → 基本信息（简介/演职人员）→ 剧评 → 选集 → 原著小说；
/// 钉住 tab = 基本信息/剧评/原著小说（**没有选集 tab**，选集区滚过时点亮
/// 的是剧评，与官方一致）；顶栏剧名在返回键右侧左对齐；选集区头部右侧带
/// 「已完结 共105集 ›」状态。
///
/// 背景/主题色（反编译源码复核，`BaseSeriesDetailFragment.Zf`/`Df`/`s0`）：
/// 服务端 `series_color_hex` 经双段 HSL 映射出顶部色与底部主色，背景 =
/// 顶部 400dp 的垂直渐变 + 其余纯主色；映射的分段点 knee 恒为 `t0` 默认
/// 0.625，输出永远落在暗色带——所以官方任何剧的背景都压得深、白字可读。
/// `Zf` 还算第三个亮 accent `HSLToColor([h, 0.5, 0.39])`（保留色相），真机
/// 实证当前集格子与「继续播放」钮用它（#943295 = HSL(300,0.5,0.39)），
/// 「收藏」钮白底、图标文字用主色，底栏本体是主色的透明→不透明渐变
/// scrim（`g1.b`）。不是封面图，也不是固定素材——同一素材图（img_665）
/// 只是 30% 亮度的半透明纹理盖在渐变上，本地省略。
///
/// 区块顺序照 2026-09-30 官方截图：头部 → 钉住 tab 行（滚过头部后吸顶）
/// → 基本信息 → 剧评（评分入口卡 + 横滑卡片）→ 选集 → 原著小说。
///
/// 与官方的差异（都有据）：
/// - 官方 tab 还有「相关作品」「猜你喜欢」。取数链路已定位：
///   `requestMultiVideoDetail`（`co3.d`）+ 相关流 `GET /reading/bookapi/
///   bookmall/cell/change/v:{n}/`——需要官方推荐上下文参数（cell/algo/AB），
///   没有真机抓包前不复刻，避免造假区块。
/// - 底部「收藏」与剧评头部评分入口卡（「看5分钟参与评分」+ 五星）按
///   无账号范围渲染但占位（SnackBar「暂未支持」，同 light more panel 先例）；
///   顶栏右侧 ⋮ 同。
/// - 剧评卡的星级来自评分体系，本地 comment 回包无该字段，不画星。
/// - 官方剧评是完整列表；本地复用 PlayletCommentPanel 的链路，页内放
///   横滑卡片预览 + 「全部剧评 ›」入口。
class SeriesDetailPage extends StatefulWidget {
  const SeriesDetailPage({
    super.key,
    required this.seriesId,
    this.title = '',
    this.cover = '',
    this.episodes = const [],
    this.startIndex = 0,
    this.watchedIds = const <String>{},
    this.seriesLoader,
    this.commentLoader,
    this.directoryLoader,
    this.onPlayEpisode,
  });

  final String seriesId;

  /// 详情接口回来前的兜底标题/封面（宿主播放页已拉过一次 seriesDetail）。
  final String title;
  final String cover;

  /// 剧集目录：宿主已有，避免二次拉目录。
  final List<Chapter> episodes;

  /// 续播/当前集下标（进详情前的播放位置）。
  final int startIndex;

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

  /// 点选集格或底部播放钮的目标行为。默认推整页播放器；宿主播放页打开
  /// 详情时传入「关闭详情 + 切集」，不叠第二个播放器。
  final ValueChanged<int>? onPlayEpisode;

  @override
  State<SeriesDetailPage> createState() => _SeriesDetailPageState();
}

class _SeriesDetailPageState extends State<SeriesDetailPage> {
  /// 官方头部规格（a34.xml）：封面 98×140dp 圆角 12、标题 20sp 最多 2 行、
  /// 分隔线 `@color/agl`=#11FFFFFF 2px、外边距水平 16。
  static const _columns = 6;

  /// 官方长剧分页（`gj3/o.java:731` setGroupByCount(30)）。
  static const _pageSize = 30;

  /// 滚过这段距离后顶栏浮现剧名（VideoCommonTitleBar 初始 gone）。
  static const _topBarRevealOffset = 150.0;

  SeriesDetail _detail = SeriesDetail.empty;
  bool _detailDone = false;

  /// feed 等入口没带目录时自拉的剧集（宿主传了 [SeriesDetailPage.episodes]
  /// 就以宿主为准，不重复请求）。
  List<Chapter> _loadedEpisodes = const [];
  bool _episodesDone = false;
  PlayletCommentPage? _comments;
  int _tab = 0;
  int _episodePage = 0;
  bool _introExpanded = false;
  bool _userScrolling = false;
  bool _scrolled = false;

  /// tab 行（SliverPersistentHeader）是否已吸顶：吸顶后内容会从下面穿过，
  /// 需要不透明背景；未吸顶时保持透明融入背景渐变。
  bool _tabsPinned = false;

  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _sectionKeys = [
    GlobalKey(),
    GlobalKey(),
    GlobalKey(),
  ];

  @override
  void initState() {
    super.initState();
    _episodePage = _pageOf(widget.startIndex);
    unawaited(_loadDetail());
    unawaited(_loadEpisodes());
    unawaited(_loadComments());
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadDetail() async {
    try {
      final detail =
          await (widget.seriesLoader?.call(widget.seriesId) ??
              ApiClient.instance.seriesDetail(widget.seriesId));
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _detailDone = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _detailDone = true);
    }
  }

  Future<void> _loadComments() async {
    if (widget.seriesId.isEmpty) return;
    try {
      final page =
          await (widget.commentLoader?.call(widget.seriesId) ??
              ApiClient.instance.playletComments(widget.seriesId, count: 10));
      if (!mounted) return;
      setState(() => _comments = page);
    } catch (_) {
      // 剧评是装饰，失败静默。
    }
  }

  Future<void> _loadEpisodes() async {
    if (widget.episodes.isNotEmpty || widget.seriesId.isEmpty) {
      _episodesDone = true;
      return;
    }
    try {
      final volumes =
          await (widget.directoryLoader?.call(widget.seriesId) ??
              ApiClient.instance.directoryChapters(
                widget.seriesId,
                tab: '短剧',
              ));
      if (!mounted) return;
      setState(() {
        _loadedEpisodes = volumes.expand((volume) => volume).toList(
          growable: false,
        );
        _episodesDone = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _episodesDone = true);
    }
  }

  /// 生效剧集：宿主带的优先，否则用自拉的。
  List<Chapter> get _episodes =>
      widget.episodes.isNotEmpty ? widget.episodes : _loadedEpisodes;

  Set<int> get _watched => watchedIndexes(widget.watchedIds, _episodes);

  String get _titleText =>
      _detail.title.isNotEmpty ? _detail.title : widget.title;

  String get _coverText =>
      _detail.cover.isNotEmpty ? _detail.cover : widget.cover;

  int _pageOf(int index) =>
      (index ~/ _pageSize).clamp(0, _lastEpisodePage);

  int get _lastEpisodePage => _episodes.isEmpty
      ? 0
      : (_episodes.length - 1) ~/ _pageSize;

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

  // ---- 官方主题色（BaseSeriesDetailFragment.Zf 的移植）----

  /// 官方 hex 解析/HSL 映射失败、或饱和度 <0.05 时的回退色
  /// （`@color/w4`）。
  static const _fallbackTheme = Color(0xFF404040);

  /// `s0.b` 的分段线性重映射：x 夹到 [0.25,1]。分段点 knee 是 `t0` 的
  /// **默认字段 0.625**（`Zf` 只经 j/h/l 设三个输出锚点，从不调 k/i/g，
  /// 所以 min=0.25、max=1、knee=0.625 对四组配置都成立）。x≤knee 时
  /// [0.25,knee] 线性映到 [outLow,outKnee]；否则 [knee,1] **反向**映到
  /// [upperTarget,outKnee]——v=knee 处取 upperTarget、v=1 处取 outKnee
  /// （knee 两侧不连续，官方代码如此）。输出恒落在 [outLow,upperTarget]
  /// 的暗色带里，这就是官方背景永远压得深、白字可读的原因。
  static double _remapHsl(
    double x,
    double outLow,
    double upperTarget,
    double outKnee,
  ) {
    const knee = 0.625;
    final v = x.clamp(0.25, 1.0);
    if (v <= knee) {
      return outLow + (v - 0.25) / (knee - 0.25) * (outKnee - outLow);
    }
    return outKnee + (1.0 - v) / (1.0 - knee) * (upperTarget - outKnee);
  }

  /// `s0.a`：品牌色 → HSL →（S<0.05 走回退）S/L 分别重映射 → 颜色。
  static Color _colorFromHex(
    String hex,
    double satLow,
    double satKnee,
    double satOut,
    double lumLow,
    double lumKnee,
    double lumOut,
  ) {
    var base = _fallbackTheme;
    var parsed = false;
    final text = hex.trim();
    final match = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(text);
    if (match != null) {
      base = Color(0xFF000000 | int.parse(match.group(1)!, radix: 16));
      parsed = true;
    }
    if (!parsed) return _fallbackTheme;
    final hsl = HSLColor.fromColor(base);
    if (hsl.saturation < 0.05) return _fallbackTheme;
    final s = _remapHsl(hsl.saturation, satLow, satKnee, satOut);
    final l = _remapHsl(hsl.lightness, lumLow, lumKnee, lumOut);
    return hsl.withSaturation(s).withLightness(l).toColor();
  }

  /// 渐变底部主色（`Zf` 的 base color：outLow=0.55、上段起点 0.7、
  /// outKnee=0.625；L：0.18 / 0.2 / 0.19）。
  Color get _themeBase => _colorFromHex(
    _detail.seriesColorHex,
    0.55,
    0.7,
    0.625,
    0.18,
    0.2,
    0.19,
  );

  /// 渐变顶部色（`Zf` 的 top color：outLow=0.35、上段起点 0.4、
  /// outKnee=0.375；L：0.3 / 0.35 / 0.325）。
  Color get _themeTop => _colorFromHex(
    _detail.seriesColorHex,
    0.35,
    0.4,
    0.375,
    0.3,
    0.35,
    0.325,
  );

  /// 亮 accent（`Zf` 的第二个颜色 `HSLToColor([hue, 0.5, 0.39])`）：保留
  /// `series_color_hex` 色相、S=0.5、L=0.39，比背景亮一档。真机实证
  /// （#943295 = HSL(300°, 0.5, 0.39)）：当前集格子与「继续播放」钮用它。
  /// hex 解析失败或灰色系时官方 catch 回退 base 主色。
  Color get _themeAccent {
    final match = RegExp(
      r'^#?([0-9a-fA-F]{6})$',
    ).firstMatch(_detail.seriesColorHex.trim());
    if (match == null) return _themeBase;
    final hsl = HSLColor.fromColor(
      Color(0xFF000000 | int.parse(match.group(1)!, radix: 16)),
    );
    if (hsl.saturation < 0.05) return _themeBase;
    return HSLColor.fromAHSL(1.0, hsl.hue, 0.5, 0.39).toColor();
  }

  void _onScroll() {
    // 官方 VideoCommonTitleBar 初始 gone，滚过头部后浮现。
    final scrolled = _scroll.hasClients && _scroll.offset > _topBarRevealOffset;
    // tab 行吸顶判定：基本信息区顶被压到 tab 行下沿（44+40）以下时，
    // SliverPersistentHeader 已钉在顶部。
    final introTop = _sectionTop(0);
    final tabsPinned =
        _scroll.hasClients && introTop <= 44 + 40 && introTop.isFinite;
    // 官方 tab 与锚点区联动；滚动经过哪个区就点亮哪个 tab。
    // 选集区没有自己的 tab（官方如此），归到上方的剧评。
    var tab = 0;
    if (_userScrolling) {
      for (var i = _tabNames.length - 1; i >= 0; i--) {
        if (_sectionTop(i) <= 0) {
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

  /// 区块顶相对视口顶的偏移。
  double _sectionTop(int index) {
    final context = _sectionKeys[index].currentContext;
    if (context == null) return double.infinity;
    final box = context.findRenderObject();
    if (box is! RenderBox) return double.infinity;
    return box.localToGlobal(Offset.zero).dy;
  }

  void _selectTab(int index) {
    setState(() => _tab = index);
    if (!_scroll.hasClients) return;
    double target;
    if (index == 0) {
      target = 0;
    } else {
      final context = _sectionKeys[index].currentContext;
      if (context == null) return;
      final box = context.findRenderObject();
      if (box is! RenderBox) return;
      // 104 ≈ 顶栏 44 + tab 行 40 + 呼吸 20：锚点吸在 tab 行下沿。
      target = _scroll.offset + _sectionTop(index) - 104;
    }
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
            kind: 'video',
            title: _titleText.isEmpty ? '第${target + 1}集' : _titleText,
            cover: _coverText,
            eps: _episodes,
            startIndex: target,
            shortSeries: true,
          ),
        ),
      ),
    );
  }

  void _openOriginalBook(SeriesRelateBook book) {
    unawaited(
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => DetailPage(
            item: MediaItem(
              id: book.id,
              title: book.title,
              cover: book.cover,
              author: '',
              badge: '原著小说',
              ep: '',
              kind: 'book',
            ),
          ),
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

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        key: const ValueKey('series-detail-page'),
        backgroundColor: _themeBase,
        body: Stack(
          children: [
            Positioned.fill(child: _backdrop()),
            SafeArea(
              child: Column(
                children: [
                  _topBar(),
                  Expanded(
                    child: NotificationListener<UserScrollNotification>(
                      onNotification: (notification) {
                        _userScrolling =
                            notification.direction != ScrollDirection.idle;
                        return false;
                      },
                      // 官方 AppBarLayout 结构：头部随内容滚走，TabLayout
                      //（40dp）滚到顶后钉在顶栏下方 —— SliverPersistentHeader
                      // 的 pinned 语义与之一致。
                      child: CustomScrollView(
                        key: const ValueKey('series-detail-content'),
                        controller: _scroll,
                        slivers: [
                          SliverToBoxAdapter(child: _header()),
                          SliverPersistentHeader(
                            pinned: true,
                            delegate: _PinnedTabsDelegate(
                              names: _tabNames,
                              activeIndex: _tab,
                              pinned: _tabsPinned,
                              background: _themeTop,
                              onTap: _selectTab,
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: KeyedSubtree(
                              key: _sectionKeys[0],
                              child: _introSection(),
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: KeyedSubtree(
                              key: _sectionKeys[1],
                              child: _commentSection(),
                            ),
                          ),
                          SliverToBoxAdapter(child: _episodeSection()),
                          if (_detail.originalBook != null)
                            SliverToBoxAdapter(
                              child: KeyedSubtree(
                                key: _sectionKeys[2],
                                child: _bookSection(_detail.originalBook!),
                              ),
                            ),
                          // 底栏是悬浮 scrim，尾部留出其高度，末行格子
                          // 滚到底也能完整露出。
                          SliverPadding(
                            padding: EdgeInsets.only(
                              bottom: 88 + MediaQuery.paddingOf(context).bottom,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_episodes.isNotEmpty)
              Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar()),
          ],
        ),
      ),
    );
  }

  /// 官方背景（`apc.xml` i9u + `Zf`/`Df`）：`series_color_hex` 推导的
  /// 顶部色→底部主色渐变**只画顶部 400dp**（`Df` 的
  /// `setLayerInset(1, 0, 0, 0, height-400dp)` 把渐变层底部内缩到 400dp），
  /// 其余露出底层纯主色。源码里还有一张 CDN 纹理
  /// （`img_665_short_video_detail_background.png`，FIT_XY + MULTIPLY 30% 白）
  /// 盖在上面，CDN 前缀是服务端 AB 配置拿不到，本地省略——半透明纹理只
  /// 带来轻微颗粒感，不影响色调。
  Widget _backdrop() => LayoutBuilder(
    builder: (context, constraints) {
      final gradientHeight = constraints.maxHeight.clamp(0.0, 400.0).toDouble();
      return Column(
        children: [
          if (gradientHeight > 0)
            SizedBox(
              height: gradientHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_themeTop, _themeBase],
                  ),
                ),
              ),
            ),
          Expanded(child: ColoredBox(color: _themeBase)),
        ],
      );
    },
  );

  /// 官方 44dp 顶栏（`c3` + VideoCommonTitleBar）：返回键常驻，剧名滚过
  /// 头部后在返回键右侧浮现（实机：`‹ 抽象三国第一季`，左对齐非居中），
  /// 右侧 ⋮ 更多钮（实机）。背景用渐变顶色 —— 背景渐变不随内容滚动，
  /// 顶栏处露出的一直是渐变顶端，同色即无缝；官方用截位背景图同理。
  Widget _topBar() => Container(
    key: const ValueKey('series-detail-topbar'),
    height: 44,
    color: _themeTop,
    child: Row(
      children: [
        IconButton(
          key: const ValueKey('series-detail-back'),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
        ),
        Expanded(
          child: AnimatedOpacity(
            opacity: _scrolled ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: Text(
              _titleText,
              key: const ValueKey('series-detail-topbar-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('series-detail-more'),
          tooltip: '更多',
          onPressed: _showMorePlaceholder,
          icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
        ),
      ],
    ),
  );

  void _showMorePlaceholder() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('更多操作暂未支持')));
  }

  /// 头部（官方 a34.xml）：封面 + 右列（标题 + 状态行 + 分类 chips）+
  /// 分隔线。chips（he3）约束在标题列内、状态行下 16dp，分隔线（2px
  /// `@color/agl`）挂在封面下方 24dp。
  Widget _header() => Padding(
    key: const ValueKey('series-detail-header'),
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cover(),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _titleBlock(),
                  if (_detail.categories.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _categories(),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Container(height: 2, color: const Color(0x11FFFFFF)),
      ],
    ),
  );

  /// 官方封面 98×140dp 圆角 12（MultiGenreBookCover）。实机详情页封面
  /// 不带状态角标——状态在状态行与选集区头部。
  Widget _cover() {
    final url = ApiClient.instance.absoluteUrl(_coverText);
    return SizedBox(
      width: 98,
      height: 140,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: url.isEmpty
            ? Container(
                color: const Color(0x14FFFFFF),
                child: const Icon(
                  Icons.movie_creation_outlined,
                  color: Color(0x99FFFFFF),
                ),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => Container(
                  color: const Color(0x14FFFFFF),
                  child: const Icon(
                    Icons.movie_creation_outlined,
                    color: Color(0x99FFFFFF),
                  ),
                ),
              ),
      ),
    );
  }

  /// 标题（20sp bold 白，最多 2 行）+ 状态行（`bp`：集数/播放量；实机
  /// 无追更数）。
  Widget _titleBlock() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _titleText,
        key: const ValueKey('series-detail-title'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          height: 1.2,
        ),
      ),
      if (_detail.episodeLabel.isNotEmpty || _detail.playCount > 0) ...[
        const SizedBox(height: 8),
        Text(
          _statusLine(),
          key: const ValueKey('series-detail-status'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, color: Color(0x99FFFFFF)),
        ),
      ],
    ],
  );

  /// 实机状态行 = `episodeLabel · 播放量`，没有追更段（官方 `bp` 布局
  /// 只有集数与播放量）。
  String _statusLine() {
    final parts = <String>[];
    if (_detail.episodeLabel.isNotEmpty) parts.add(_detail.episodeLabel);
    if (_detail.playCount > 0) parts.add('${_detail.playLabel}次播放');
    return parts.join(' · ');
  }

  /// 官方 RecommendTagLayout 分类 chips（8dp 间距，右侧带 › 箭头，
  /// 实机「逆袭 ›」「时空之旅 ›」）。
  Widget _categories() => Wrap(
    key: const ValueKey('series-detail-categories'),
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final name in _detail.categories)
        Container(
          padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
          decoration: BoxDecoration(
            color: const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                style: const TextStyle(fontSize: 12, color: Color(0xE6FFFFFF)),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 14,
                color: Color(0x99FFFFFF),
              ),
            ],
          ),
        ),
    ],
  );

  // ---- 选集区 ----

  /// 选集区块（官方 `cin.xml`）：顶部 1px `@color/agh`=#08FFFFFF 分隔线
  /// （左右缩进 16、上下留 20），标题行（16sp 白粗 + 右侧 12sp `@color/agw`
  /// =#66FFFFFF 状态 + 箭头），分页条与格子网格。
  Widget _episodeSection() {
    final statusText = _episodes.isEmpty ? null : _episodeStatusText;
    final header = _sectionHeader(
      '选集',
      trailing: statusText == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  statusText,
                  key: const ValueKey('series-episode-status'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0x66FFFFFF),
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 14,
                  color: Color(0x66FFFFFF),
                ),
              ],
            ),
    );
    Widget body;
    if (_episodes.isEmpty) {
      // 自拉目录在途先不出「暂无」，避免 feed 入口闪一下空态。
      if (!_episodesDone) {
        body = const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: SizedBox(
              key: ValueKey('series-episodes-loading'),
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0x99FFFFFF),
              ),
            ),
          ),
        );
      } else {
        body = const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              '暂无剧集',
              key: ValueKey('series-episodes-empty'),
              style: TextStyle(color: Color(0x99FFFFFF)),
            ),
          ),
        );
      }
      return _episodeSectionShell(header, body);
    }
    if (_episodes.length <= _pageSize) {
      body = _episodeGrid();
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_pagingStrip(), _episodeGrid()],
      );
    }
    return _episodeSectionShell(header, body);
  }

  /// `cin.xml` 骨架：分隔线 + 标题行 + 内容（分页条/格子）。
  Widget _episodeSectionShell(Widget header, Widget body) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        margin: const EdgeInsets.fromLTRB(16, 20, 16, 20),
        height: 1,
        color: const Color(0x08FFFFFF),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [header, const SizedBox(height: 12), body],
        ),
      ),
    ],
  );

  Padding _sectionPadding({Key? key, required Widget child}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: child,
  );

  /// 区块标题（官方 `cin.xml`/`a36.xml`：16sp 白粗）+ 可选灰色计数与右侧
  /// 入口。
  Widget _sectionHeader(String title, {String? leadingCount, Widget? trailing}) =>
      Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          if (leadingCount != null)
            Text(
              leadingCount,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Color(0x99FFFFFF),
              ),
            ),
          const Spacer(),
          ?trailing,
        ],
      );

  /// 官方长剧分页条（1-30 / 31-60 …）。
  Widget _pagingStrip() => SizedBox(
    key: const ValueKey('series-episode-pages'),
    height: 36,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        for (var page = 0; page <= _lastEpisodePage; page++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _episodePage = page),
              child: Center(
                child: Text(
                  '${page * _pageSize + 1}-'
                  '${((page + 1) * _pageSize).clamp(0, _episodes.length)}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: page == _episodePage
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: page == _episodePage
                        ? Colors.white
                        : const Color(0xB3FFFFFF),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  /// 官方选集网格（`cin.xml` d0a 分页 + czs 网格；格子规格见
  /// `_episodeTile`）。竖屏 6 列。
  Widget _episodeGrid() {
    final start = _episodePage * _pageSize;
    final end = ((start + _pageSize)).clamp(0, _episodes.length);
    final count = end - start;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: GridView.count(
        key: const ValueKey('series-episode-grid'),
        crossAxisCount: _columns,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        // 官方格子高≈宽×52/53（story_player_panel 同式）。
        childAspectRatio: 53 / 52,
        children: [
          for (var i = start; i < start + count; i++) _episodeTile(i),
        ],
      ),
    );
  }

  /// 官方详情页选集格子（`bbw.xml` 53×52dp 圆角 8，深色皮肤）：当前集
  /// 亮 accent 底白字（真机 #943295，`HSLToColor([h,0.5,0.39])`）+ 右上角
  /// `video_playing_orange.json` 角标（12×12dp，margin 4）；普通格白 10% 底
  /// （实机量得）白字；已看 #66FFFFFF 灰字；不可播压暗。角标静止——
  /// 官方 lottie 也只在确认真实播放时才 autoplay，详情页不追踪播放状态。
  Widget _episodeTile(int index) {
    final episode = _episodes[index];
    final isCurrent = index == widget.startIndex;
    final watched = _watched.contains(index);
    final background = episode.disabled
        ? const Color(0x0DFFFFFF)
        : isCurrent
        ? _themeAccent
        : const Color(0x1AFFFFFF);
    final textColor = episode.disabled
        ? const Color(0x33FFFFFF)
        : isCurrent
        ? Colors.white
        : watched
        ? const Color(0x66FFFFFF)
        : Colors.white;
    return Semantics(
      key: ValueKey('series-episode-$index'),
      label: '第 ${index + 1} 集',
      button: true,
      selected: isCurrent,
      excludeSemantics: true,
      onTap: () => _play(index),
      child: Material(
        color: background,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _play(index),
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
                    fontWeight: isCurrent && !episode.disabled
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: textColor,
                  ),
                ),
              ),
              if (isCurrent && !episode.disabled)
                Positioned(
                  top: 4,
                  right: 4,
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: Lottie.asset(
                      'assets/lottie/video_playing_orange.json',
                      animate: false,
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

  // ---- 基本信息区 ----

  Widget _introSection() {
    final hasIntro = !_detailDone || _detail.intro.isNotEmpty;
    final hasCast = _detail.cast.isNotEmpty;
    return Padding(
      key: const ValueKey('series-detail-intro-section'),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 官方 a36.xml：区块标题 16sp 白粗（`@dimen/r2` + style x4），
          // 40dp 行高。
          SizedBox(
            height: 40,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '基本信息',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          if (hasIntro) ...[
            const SizedBox(height: 7),
            _introBlock(),
          ],
          if (hasCast) ...[
            const SizedBox(height: 24),
            const Text(
              '演职人员',
              key: ValueKey('series-detail-cast-title'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            _castRow(),
          ],
        ],
      ),
    );
  }

  static const _introCollapsedLines = 3;

  /// 官方 `awv` = #FF82A5CD，2026-09-30 取证定位到的「展开/收起」链接色。
  static const _introLinkColor = Color(0xFF82A5CD);

  /// 官方简介折叠态（a36.xml + `DetailIntroductionLayout`）：正文 14sp
  /// `@color/b6`=#B3FFFFFF 最多 3 行，蓝色「展开」叠在正文右下角（约束
  /// bottom/right 对齐正文）；官方靠 `checkIsEllipsized` 给标签留位。
  /// Flutter 没有原生"末行留白"，用 TextPainter 二分出恰好容纳
  /// 「…＋标签宽」的前缀，正文全宽渲染、标签叠右下，观感与官方一致。
  Widget _introBlock() {
    const bodyStyle = TextStyle(
      fontSize: 14,
      height: 1.4,
      color: Color(0xB3FFFFFF),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (_introExpanded) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _detail.intro,
                key: const ValueKey('series-detail-intro'),
                style: bodyStyle,
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: _introToggleLabel('收起'),
              ),
            ],
          );
        }
        final prefix = _collapsedIntroPrefix(
          _detail.intro,
          maxWidth,
          bodyStyle,
        );
        if (prefix == null) {
          // 不足 3 行：官方直接不显示展开钮。
          return Text(
            _detail.intro,
            key: const ValueKey('series-detail-intro'),
            style: bodyStyle,
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _introExpanded = true),
          child: Stack(
            children: [
              // 前缀按「末行让出标签宽度」二分裁剪，正文全宽渲染。
              Text(
                '$prefix…',
                key: const ValueKey('series-detail-intro'),
                style: bodyStyle,
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Text(
                  '展开',
                  style: const TextStyle(
                    fontSize: 14,
                    color: _introLinkColor,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _introToggleLabel(String label) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => setState(() => _introExpanded = !_introExpanded),
    child: Text(
      label,
      style: const TextStyle(fontSize: 14, color: _introLinkColor),
    ),
  );

  /// 折叠前缀：正文 3 行放不下时，二分出「`prefix…` 不超 3 行且末行宽度
  /// 给右下角标签让位」的最大前缀；不溢出返回 null（调用方整段展示）。
  String? _collapsedIntroPrefix(
    String text,
    double maxWidth,
    TextStyle style,
  ) {
    final overflowProbe = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    if (overflowProbe.computeLineMetrics().length <= _introCollapsedLines) {
      return null;
    }
    final labelProbe = TextPainter(
      text: const TextSpan(text: ' 展开', style: TextStyle(fontSize: 14)),
      textDirection: TextDirection.ltr,
    )..layout();
    final reserved = labelProbe.width + 8;
    String? best;
    var lo = 0;
    var hi = text.length;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final probe = TextPainter(
        text: TextSpan(
          text: '${text.substring(0, mid)}…',
          style: style,
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      final metrics = probe.computeLineMetrics();
      if (metrics.length > _introCollapsedLines ||
          metrics.last.width > maxWidth - reserved) {
        hi = mid - 1;
      } else {
        best = text.substring(0, mid);
        lo = mid + 1;
      }
    }
    return best ?? '';
  }

  /// 官方 ShortSeriesDetailCelebrityLayoutV2：圆头像 + 「演员 饰 角色」。
  Widget _castRow() => SizedBox(
    key: const ValueKey('series-detail-cast'),
    height: 96,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _detail.cast.length,
      separatorBuilder: (_, _) => const SizedBox(width: 16),
      itemBuilder: (context, index) {
        final member = _detail.cast[index];
        return SizedBox(
          width: 64,
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  color: Color(0x14FFFFFF),
                  shape: BoxShape.circle,
                ),
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                child: member.avatar.isEmpty
                    ? Text(
                        member.initial,
                        style: const TextStyle(
                          fontSize: 20,
                          color: Colors.white,
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: ApiClient.instance.absoluteUrl(
                          member.avatar,
                        ),
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => Text(
                          member.initial,
                          style: const TextStyle(
                            fontSize: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                member.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0x99FFFFFF),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  // ---- 原著小说区 ----

  /// 官方独立区块「原著小说」：标题 + 书行（封面/书名/灰色状态行）+
  /// 右侧「立即阅读」胶囊钮（实机样式）。
  Widget _bookSection(SeriesRelateBook book) => _sectionPadding(
    key: const ValueKey('series-detail-original-book'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('原著小说'),
        const SizedBox(height: 12),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openOriginalBook(book),
          child: _bookRow(book),
        ),
      ],
    ),
  );

  Widget _bookRow(SeriesRelateBook book) => Container(
    height: 64,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: const Color(0x0AFFFFFF),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: book.cover.isEmpty
              ? const SizedBox(
                  width: 40,
                  height: 52,
                  child: ColoredBox(color: Color(0x14FFFFFF)),
                )
              : CachedNetworkImage(
                  imageUrl: ApiClient.instance.absoluteUrl(book.cover),
                  width: 40,
                  height: 52,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => const SizedBox(
                    width: 40,
                    height: 52,
                    child: ColoredBox(color: Color(0x14FFFFFF)),
                  ),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Text(
            '立即阅读',
            style: TextStyle(fontSize: 13, color: Colors.white),
          ),
        ),
      ],
    ),
  );

  // ---- 剧评区 ----

  /// 官方样式（实机）：头部「剧评 · 127」+ 右侧「全部剧评 ›」，下方横滑
  /// 大卡片（头像/昵称 + 右上点赞数 + 正文）。官方卡片里的星级评分来自
  /// 评分体系，本地链路无该字段，不画星。
  Widget _commentSection() {
    final comments = _comments?.comments ?? const <PlayletComment>[];
    final total = _comments?.totalCount ?? _detail.commentCount;
    return _sectionPadding(
      key: const ValueKey('series-detail-comment-section'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            '剧评',
            leadingCount: total > 0 ? ' · ${formatCounter('$total')}' : null,
            trailing: comments.isEmpty
                ? null
                : GestureDetector(
                    key: const ValueKey('series-detail-comments-all'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _openAllComments,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '全部剧评',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0x99FFFFFF),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: Color(0x99FFFFFF),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          // 官方评分入口卡（实机）：左侧引导文案 + 右侧五星，评分走账号
          // 体系，本地按占位渲染（轻点 SnackBar，同 light more panel 先例）。
          GestureDetector(
            key: const ValueKey('series-detail-rate-card'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('评分暂未支持')),
              );
            },
            child: Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0x14FFFFFF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '看5分钟参与评分',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  for (var i = 0; i < 5; i++)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.star_rounded,
                        size: 24,
                        color: Color(0x66FFFFFF),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (comments.isEmpty)
            Text(
              _comments == null ? '' : '期待你的第一条剧评',
              key: const ValueKey('series-detail-comments-empty'),
              style: const TextStyle(
                fontSize: 13,
                color: Color(0x99FFFFFF),
              ),
            )
          else
            SizedBox(
              height: 148,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: comments.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) =>
                    _commentCard(comments[index]),
              ),
            ),
        ],
      ),
    );
  }

  /// 官方横滑剧评卡：宽约 78% 屏宽（实机量得 ≈0.79）、白 7% 底、圆角 12。
  Widget _commentCard(PlayletComment comment) => Container(
    width: MediaQuery.sizeOf(context).width * 0.78,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0x12FFFFFF),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(
                color: Color(0x14FFFFFF),
                shape: BoxShape.circle,
              ),
              clipBehavior: Clip.antiAlias,
              alignment: Alignment.center,
              child: comment.userAvatar.isEmpty
                  ? Text(
                      comment.userName.isEmpty
                          ? '?'
                          : String.fromCharCode(
                              comment.userName.runes.first,
                            ),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white,
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: ApiClient.instance.absoluteUrl(
                        comment.userAvatar,
                      ),
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => Text(
                        comment.userName.isEmpty
                            ? '?'
                            : String.fromCharCode(
                                comment.userName.runes.first,
                              ),
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                comment.userName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xCCFFFFFF),
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.favorite_border_rounded,
              size: 15,
              color: Color(0x99FFFFFF),
            ),
            const SizedBox(width: 3),
            Text(
              comment.diggCount > 0
                  ? formatCounter('${comment.diggCount}')
                  : '',
              style: const TextStyle(fontSize: 12, color: Color(0x99FFFFFF)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Text(
            comment.text,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              height: 1.35,
              color: Colors.white,
            ),
          ),
        ),
      ],
    ),
  );

  // ---- 底部栏 ----

  /// 官方底栏（`g1.b`，ConstraintLayout 背景是主色四段渐变 scrim：
  /// [α0, α0xB4, αFF, αFF] 自上而下，内容从半透明区穿过）+ 双钮：
  /// 「收藏」白底胶囊、图标文字用主色（`n(i(), -1)` 白底 + setColorFilter
  /// 主色）；「继续播放」亮 accent 底（`n(l(), i3)`）白字白图标。文案照
  /// 官方 `@string/bcs`=「继续播放」（实机核对，不带集号）；无进度时
  /// 「立即播放」未逐字取证。收藏走账号，按无账号范围占位（SnackBar）。
  Widget _bottomBar() {
    final label = widget.startIndex > 0 ? '继续播放' : '立即播放';
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Container(
      key: const ValueKey('series-detail-bottombar'),
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        12 + bottomInset,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, 1 / 3, 2 / 3, 1],
          colors: [
            _themeBase.withAlpha(0x00),
            _themeBase.withAlpha(0xB4),
            _themeBase,
            _themeBase,
          ],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              key: const ValueKey('series-detail-fav-button'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('收藏暂未支持')),
                );
              },
              child: Container(
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.star_border_rounded,
                      size: 20,
                      color: _themeBase,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '收藏',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: _themeBase,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              key: const ValueKey('series-detail-play-button'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _play(widget.startIndex),
              child: Container(
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _themeAccent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.play_arrow_rounded,
                      size: 22,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 官方 `cm` TabLayout 的吸顶实现：40dp 钉住头，滚过头部前透明融入背景
/// 渐变，吸顶后垫 `background`（顶色）避免内容从字下穿过。
class _PinnedTabsDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedTabsDelegate({
    required this.names,
    required this.activeIndex,
    required this.pinned,
    required this.background,
    required this.onTap,
  });

  final List<String> names;
  final int activeIndex;
  final bool pinned;
  final Color background;
  final ValueChanged<int> onTap;

  @override
  double get minExtent => 40;

  @override
  double get maxExtent => 40;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      key: const ValueKey('series-detail-tabs'),
      height: 40,
      color: pinned ? background : Colors.transparent,
      child: Row(
        children: [
          for (var i = 0; i < names.length; i++)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: Text(
                    names[i],
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: i == activeIndex
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: i == activeIndex
                          ? Colors.white
                          : const Color(0xB3FFFFFF),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_PinnedTabsDelegate oldDelegate) =>
      oldDelegate.activeIndex != activeIndex ||
      oldDelegate.pinned != pinned ||
      oldDelegate.background != background ||
      oldDelegate.names.length != names.length;
}
