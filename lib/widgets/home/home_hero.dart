import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/search_discovery.dart';
import 'home_design.dart';

/// 官方书城顶栏（`res/layout/alx.xml` 的 `fua` 搜索行）。
///
/// 2026-10-26 首页重做后不再逐像素对齐官方：搜索框从 36dp / 6dp 圆角改成
/// 40dp / 20dp 的胶囊，右端「分类」入口同高同圆角。下面是官方的原尺寸，
/// 留作对照（文案与热搜轮换仍与官方一致）。
///
/// 官方在这一层是一条 51dp 的搜索行：`SearchWordDisplayView`（`h21`）占
/// 剩余宽度，左 16dp 右 16dp；右上角是「分类」入口 `i_y`（默认 gone，由
/// AB 位 `hasCategoryTab()==false` 时打开）——14dp 分类图 + 2dp 间隔 +
/// 14sp「分类」，高 `zl`=36dp，左右 padding 10dp，圆角 8dp 的白色底
/// （`skin_bg_top_right_holder_light` = `skin_color_search_bar_bg_v2_light`）。
///
/// 搜索框本体（`c5e.xml`）：36dp 高、6dp 圆角、白底；左侧 11dp 放大镜。
/// 官方框内的「识剧」图文入口（`search_image_icon_container`）按用户决定
/// 不做（2026-10-24，链路未接入），已删除。框内文案由 `search/cue/v` 的
/// 热搜词驱动（`SearchWordDisplayView` + `VerticalFlipper`，间隔取响应的
/// `rotate_interval_ms`）；没有词时回退静态提示语 `@string/duw`。
class HomeHero extends StatefulWidget {
  static const double searchBarHeight = 40;
  static const double searchBarRadius = 20;

  /// 搜索行在宽屏上的最大宽度。手机与平板永远吃不满这一档，只有桌面需要
  /// 它兜住：没有上限时窗口多宽、那条空胶囊就多宽，「分类」被挤到最右。
  /// 1120 ≈ 6 列书卡（6×180 + 5×12 + 32 栏距），与网格左端同一条竖线。
  static const double maxToolbarWidth = 1120;

  /// 官方 `@string/duw`：`SearchWordDisplayView` 的默认文案。
  static const String searchHint = '请输入书名或作者名';

  /// 官方 `@string/gl`。
  static const String categoryLabel = '分类';

  final VoidCallback onSearch;

  /// 右上角「分类」入口。null 时不占位（与官方 `i_y` gone 一致）。
  final VoidCallback? onCategory;

  /// 搜索框热搜词（`/api/v1/search/cue`）。null 表示不接入——测试与离线
  /// 场景框内保持静态提示语；拉取失败同样回退静态提示语。
  final Future<SearchCue> Function()? cueLoader;

  const HomeHero({
    super.key,
    required this.onSearch,
    this.onCategory,
    this.cueLoader,
  });

  @override
  State<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends State<HomeHero> {
  List<String> _words = const [];
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final loader = widget.cueLoader;
    if (loader == null) return;
    // 热搜词是锦上添花：loader 同步或异步失败都不能波及页面，框内保持
    // 静态提示语即可。
    Future<SearchCue> future;
    try {
      future = loader();
    } catch (_) {
      return;
    }
    future
        .then((cue) {
          if (!mounted || cue.isEmpty) return;
          setState(() => _words = cue.words);
          _startRotation(cue.rotateIntervalMs);
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startRotation(int intervalMs) {
    // 官方 `VerticalFlipper` 也只在多于一条时有翻页的意义。
    if (_words.length < 2) return;
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      // 页面切走（IndexedStack 里未选中）时暂停轮换，回来后下一拍继续。
      if (!mounted || !TickerMode.valuesOf(context).enabled) return;
      setState(() => _index = (_index + 1) % _words.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Padding(
      // 官方 fua：paddingTop 6dp / paddingBottom 9dp，左右 16dp。
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      // 桌面宽窗里不再把搜索行拉满整条：2560 的窗口下一枚 2528 宽的空胶囊
      // 只剩一条灰带，「分类」还被推到窗口最右端。工具栏收到
      // [HomeHero.maxToolbarWidth]——约等于 6 张卡片的宽度，左端仍与网格、
      // 分区头同一条 16dp 竖线。
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: HomeHero.maxToolbarWidth),
        child: Row(
          children: [
            Expanded(
              child: HomePressable(
                key: const Key('home_search_button'),
                onTap: widget.onSearch,
                borderRadius: BorderRadius.circular(HomeHero.searchBarRadius),
                semanticLabel: HomeHero.searchHint,
                child: Container(
                  height: HomeHero.searchBarHeight,
                  padding: const EdgeInsets.only(left: 16, right: 14),
                  decoration: BoxDecoration(
                    color: palette.searchBar,
                    borderRadius: BorderRadius.circular(
                      HomeHero.searchBarRadius,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(LucideIcons.search, size: 15, color: palette.muted),
                      const SizedBox(width: 10),
                      Expanded(child: _cueText(palette, animate)),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.onCategory != null) ...[
              const SizedBox(width: 16),
              _categoryPill(palette),
            ],
          ],
        ),
      ),
    );
  }

  /// 热搜词轮换位：官方 `VerticalFlipper` 淡入淡出；无词时是静态提示语。
  Widget _cueText(HomePalette palette, bool animate) {
    final text = _words.isEmpty ? HomeHero.searchHint : _words[_index];
    final word = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      key: ValueKey<String>(text),
      style: TextStyle(fontSize: 13.5, color: palette.searchBarText),
    );
    if (!animate) return word;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previousChildren, ?currentChild],
      ),
      child: word,
    );
  }

  /// 搜索行右端的「分类」入口：与搜索框同高同圆角的 40dp 胶囊。
  Widget _categoryPill(HomePalette palette) {
    return GestureDetector(
      key: const Key('home_category_button'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.onCategory,
      child: Container(
        height: HomeHero.searchBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: palette.searchBar,
          borderRadius: BorderRadius.circular(HomeHero.searchBarRadius),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.layout_grid, size: 15, color: palette.ink),
            const SizedBox(width: 5),
            Text(
              HomeHero.categoryLabel,
              style: TextStyle(fontSize: 13, color: palette.ink),
            ),
          ],
        ),
      ),
    );
  }
}
