import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:cached_network_image/cached_network_image.dart';

import '../models/book_detail.dart' show formatCounter;
import '../models/media_item.dart';
import '../models/playlet_comment.dart';
import '../models/series_detail.dart' show SeriesDetail, SeriesRelateBook;
import '../services/api_client.dart';
import '../services/watched_episodes.dart' show watchedIndexes;
import '../widgets/player/playlet_comment_panel.dart';
import '../widgets/player/story_player_panel.dart'
    show EpisodeTileState, SeriesStatus, episodeTileLabel;
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
/// 上（到距底 400dp）垂直渐变 + 底部纯主色；当前集格子与播放钮用主色。
/// 不是封面图，也不是固定素材——同一素材图（img_665）只是 30% 亮度的
/// 半透明纹理盖在渐变上，本地省略。
///
/// 与官方的差异（都有据）：
/// - 官方底部是「收藏 + 继续播放」双钮；收藏要走账号，本仓库按
///   「无账号范围」裁掉（2026-09-26 short-drama-no-account-scope 笔记），
///   保留单个主钮，宽度照 `g1.c` 单钮分支 = 70% 屏宽。
/// - 官方 tab 还有「相关作品」「猜你喜欢」，且剧评头部有评分入口（轻点
///   评分）——本地 `video_detail` 链路没有相关剧集与评分数据，裁掉；
///   相关作品的取数接口是后续取证项。
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

  /// `s0.b` 的分段线性重映射：x 夹到 [0.25, 1]，x≤knee 时 [0.25,knee] 线性
  /// 映到 [outLow, outKnee]，否则 [knee,1] 映到 [outKnee,1]（暗端反向拉亮）。
  static double _remapHsl(double x, double outLow, double knee, double outKnee) {
    final v = x.clamp(0.25, 1.0);
    if (v <= knee) {
      return outLow + (v - 0.25) / (knee - 0.25) * (outKnee - outLow);
    }
    return outKnee + (1.0 - v) / (1.0 - knee) * (1.0 - outKnee);
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

  /// 渐变底部主色（`Zf` 的 base color：S→[0.55,0.625]@0.7，L→[0.18,0.19]@0.2）。
  Color get _themeBase => _colorFromHex(
    _detail.seriesColorHex,
    0.55,
    0.7,
    0.625,
    0.18,
    0.2,
    0.19,
  );

  /// 渐变顶部色（`Zf` 的 top color：S→[0.35,0.375]@0.4，L→[0.3,0.325]@0.4）。
  Color get _themeTop => _colorFromHex(
    _detail.seriesColorHex,
    0.35,
    0.4,
    0.375,
    0.3,
    0.4,
    0.325,
  );

  void _onScroll() {
    // 官方 VideoCommonTitleBar 初始 gone，滚过头部后浮现。
    final scrolled = _scroll.hasClients && _scroll.offset > _topBarRevealOffset;
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
    if (scrolled == _scrolled && (!_userScrolling || tab == _tab)) return;
    setState(() {
      _scrolled = scrolled;
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
                  // 官方 TabLayout 挂在 AppBarLayout 上（`cm`，40dp），
                  // 滚动时钉在顶栏下方，不随内容滚走。
                  _tabs(),
                  Expanded(
                    child: NotificationListener<UserScrollNotification>(
                      onNotification: (notification) {
                        _userScrolling =
                            notification.direction != ScrollDirection.idle;
                        return false;
                      },
                      child: _content(),
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
  /// 顶部色→底部主色渐变层（到距底 400dp 为止）+ 底部纯主色。源码里还有
  /// 一张 CDN 纹理（`img_665_short_video_detail_background.png`，FIT_XY +
  /// MULTIPLY 30% 白）盖在上面，CDN 前缀是服务端 AB 配置拿不到，本地省略
  /// ——半透明纹理只带来轻微颗粒感，不影响色调。
  Widget _backdrop() => LayoutBuilder(
    builder: (context, constraints) {
      final gradientHeight = constraints.maxHeight - 400.0;
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
  /// 头部后在返回键右侧浮现（实机：`‹ 抽象三国第一季`，左对齐非居中）。
  Widget _topBar() => SizedBox(
    key: const ValueKey('series-detail-topbar'),
    height: 44,
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
      ],
    ),
  );

  Widget _content() => ListView(
    key: const ValueKey('series-detail-content'),
    controller: _scroll,
    padding: EdgeInsets.only(
      bottom: 88 + MediaQuery.paddingOf(context).bottom,
    ),
    children: [
      _header(),
      // 区块顺序照官方实机：基本信息 → 剧评 → 选集（无 tab）→ 原著小说。
      KeyedSubtree(key: _sectionKeys[0], child: _introSection()),
      KeyedSubtree(key: _sectionKeys[1], child: _commentSection()),
      _episodeSection(),
      if (_detail.originalBook != null)
        KeyedSubtree(
          key: _sectionKeys[2],
          child: _bookSection(_detail.originalBook!),
        ),
    ],
  );

  /// 头部（官方 a34.xml）：封面 + 标题 + 状态行 + 分类 chips + 分隔线。
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
            Expanded(child: _titleBlock()),
          ],
        ),
        if (_detail.categories.isNotEmpty) ...[
          const SizedBox(height: 12),
          _categories(),
        ],
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

  /// 标题（20sp bold 白，最多 2 行）+ 状态行（集数/播放量/追更数）。
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
      if (_detail.episodeLabel.isNotEmpty ||
          _detail.playCount > 0 ||
          _detail.followerCount > 0) ...[
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

  String _statusLine() {
    final parts = <String>[];
    if (_detail.episodeLabel.isNotEmpty) parts.add(_detail.episodeLabel);
    if (_detail.playCount > 0) parts.add('${_detail.playLabel}次播放');
    if (_detail.followerCount > 0) {
      parts.add('${formatCounter('${_detail.followerCount}')}人追更');
    }
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

  /// 官方 40dp tab 行（`cm` TabLayout：padding 12、无指示器），tab 集合
  /// 照实机：基本信息 / 剧评 /（有原著时）原著小说。
  Widget _tabs() {
    final names = _tabNames;
    return SizedBox(
      key: const ValueKey('series-detail-tabs'),
      height: 40,
      child: Row(
        children: [
          for (var i = 0; i < names.length; i++)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _selectTab(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: Text(
                    names[i],
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: i == _tab
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: i == _tab
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

  // ---- 选集区 ----

  Widget _episodeSection() {
    final statusText = _episodes.isEmpty ? null : _episodeStatusText;
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
      return _sectionPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_sectionHeader('选集'), body],
        ),
      );
    }
    if (_episodes.length <= _pageSize) {
      body = _episodeGrid();
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_pagingStrip(), _episodeGrid()],
      );
    }
    return _sectionPadding(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
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
                          fontSize: 13,
                          color: Color(0x99FFFFFF),
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: Color(0x99FFFFFF),
                      ),
                    ],
                  ),
          ),
          body,
        ],
      ),
    );
  }

  Padding _sectionPadding({Key? key, required Widget child}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: child,
  );

  /// 区块标题（实机 18sp 白粗）+ 可选灰色计数与右侧入口。
  Widget _sectionHeader(String title, {String? leadingCount, Widget? trailing}) =>
      Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
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

  /// 官方选集格子（`bbw.xml` 规格，与播放页选集面板同源）：
  /// 当前集橙字橙底、已看灰字、普通格底 #08000000。竖屏 6 列。
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

  Widget _episodeTile(int index) {
    final episode = _episodes[index];
    final isCurrent = index == widget.startIndex;
    final state = EpisodeTileState.of(
      current: isCurrent,
      watched: _watched.contains(index),
      disabled: episode.disabled,
    );
    // 官方详情页当前集 = 主题主色底白字（非播放页面板的橙色常量，
    // `R.f(baseColor)` 的本地对应）。
    final background = isCurrent && !episode.disabled
        ? _themeBase
        : state.backgroundColor;
    final textColor = isCurrent && !episode.disabled
        ? Colors.white
        : state.textColor;
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
          child: Center(
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
                color: textColor,
              ),
            ),
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
          if (hasIntro) _introBlock(),
          if (hasCast) ...[
            const SizedBox(height: 24),
            const Text(
              '演职人员',
              key: ValueKey('series-detail-cast-title'),
              style: TextStyle(
                fontSize: 18,
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

  /// 官方 DetailIntroductionLayout：两行收起 + 展开按钮。
  Widget _introBlock() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => setState(() => _introExpanded = !_introExpanded),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _detail.intro,
          key: const ValueKey('series-detail-intro'),
          maxLines: _introExpanded ? 20 : 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            height: 1.4,
            color: Color(0xE6FFFFFF),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _introExpanded ? '收起' : '展开',
          style: const TextStyle(fontSize: 13, color: Color(0x99FFFFFF)),
        ),
      ],
    ),
  );

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

  /// 官方横滑剧评卡：宽约 73% 屏宽、微亮底、圆角 12。
  Widget _commentCard(PlayletComment comment) => Container(
    width: MediaQuery.sizeOf(context).width * 0.73,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0x0FFFFFFF),
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

  /// 官方 56dp 底栏（`hp`）；单主钮宽 70% 屏宽（`g1.c` 单钮分支）、圆角胶囊
  /// 底色=主题主色白字（实机：抽象三国金钮 / 转业保安青蓝钮，都来自
  /// `series_color_hex` 推导的 base color）。文案照官方 `@string/bcs`=
  /// 「继续播放」（实机核对，不带集号）；无进度时的「立即播放」未逐字取证。
  Widget _bottomBar() {
    final label = widget.startIndex > 0 ? '继续播放' : '立即播放';
    return Container(
      key: const ValueKey('series-detail-bottombar'),
      color: _themeBase,
      padding: EdgeInsets.fromLTRB(
        16,
        6,
        16,
        6 + MediaQuery.paddingOf(context).bottom,
      ),
      child: Center(
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width * 0.7,
          height: 44,
          child: GestureDetector(
            key: const ValueKey('series-detail-play-button'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _play(widget.startIndex),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _themeBase,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.play_arrow_rounded,
                    size: 22,
                    color: Colors.white,
                  ),
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
      ),
    );
  }

  /// 主钮/当前集格子用 base 主色本体（官方 `R.f(baseColor)` 的 accent 落点）。
}
