import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'ambient_backdrop.dart';
import 'home_design.dart';

class HomeCategory {
  final String label;
  final IconData icon;

  const HomeCategory(this.label, this.icon);
}

const homeCategories = [
  HomeCategory('推荐', LucideIcons.sparkles),
  HomeCategory('小说', LucideIcons.book_open),
  HomeCategory('短剧', LucideIcons.clapperboard),
  HomeCategory('漫剧', LucideIcons.film),
  HomeCategory('漫画', LucideIcons.image),
  HomeCategory('听书', LucideIcons.headphones),
];

class HomeTabBarDelegate extends SliverPersistentHeaderDelegate {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final double extent;
  final bool dark;

  /// 墨水屏与 OLED 两档会换掉画布、线条和柔色，但都不改变 [dark]：OLED
  /// 只在深色下生效（深色仍是深色），墨水屏本身也是浅色外观。所以它们
  /// 必须各自单列进 [shouldRebuild]，否则切换后吸顶条会保留旧色板。
  final bool eink;
  final bool oled;

  /// 背景层的控制器。吸顶后要把同一段暖光铺在自己底下，需要知道滚动到哪了。
  final ScrollController? scroll;

  /// 吸顶条顶边在屏幕坐标里的位置。首页的滚动视图在 [SafeArea] 里面，
  /// MediaQuery 的 padding 已经被它抹成 0，所以状态栏高度只能由页面传进来。
  final double topInset;

  /// 页面宽度。暖光背景层铺满整页，吸顶条却在居中的内容列里（平板横屏
  /// 1024 下栏宽只有 840），要按这个宽度画渐变再减掉列左边距，段内才是
  /// 背景层同一张渐变的下半段。0（未知）时退回按吸顶条自己的宽度画。
  final double viewportWidth;

  HomeTabBarDelegate({
    required this.selectedIndex,
    required this.onSelect,
    this.extent = 54,
    this.dark = false,
    this.eink = false,
    this.oled = false,
    this.scroll,
    this.topInset = 0,
    this.viewportWidth = 0,
  });

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final palette = HomePalette.of(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);

    // 吸顶后确实需要一块不透明画布挡住下面滚过的卡片；停在顶部时保持
    // 透明，让首页顶部的暖光从频道条里穿过去，不再被这一行切成一条直边。
    // 判据用 shrinkOffset：固定高度的吸顶头在 pinned 后 overlapsContent
    // 反而回到 false（它描述的是上一条 sliver 的覆盖）。
    final pinned = shrinkOffset > 0;
    // 画布一层不够：吸顶条的顶边正好落在状态栏下沿，上面的暖光还在，
    // 段内却是纯画布，两种外观都会在吸顶边上出现一条硬横边。
    final showWash = pinned && scroll != null && !palette.eink;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: pinned ? palette.canvas : Colors.transparent,
        border: pinned
            ? Border(
                bottom: BorderSide(
                  color: palette.line.withValues(alpha: 0.5),
                  width: 0.6,
                ),
              )
            : null,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showWash)
            // 暖光层比吸顶条高出一截：它要和背景层一样随滚动上移，
            // 层高不够时平移后底部会露出纯画布。由 Stack 负责裁剪。
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              bottom: -homeWashMaxTravel,
              child: HomePinnedWash(
                key: const ValueKey('home_pinned_wash'),
                scroll: scroll!,
                palette: palette,
                top: topInset,
                viewportWidth: viewportWidth,
              ),
            ),
          Center(
            child: SizedBox(
              // 视口撑满整条 header，胶囊再用 38 高居中：选中 tag 的红色
              // 光晕上下各有 8px 可以散开，不会被 ListView 的视口裁成硬边。
              height: extent,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemCount: homeCategories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final selected = index == selectedIndex;
                  final category = homeCategories[index];
                  return Center(
                    child: SizedBox(
                      height: 38,
                      child: Semantics(
                        selected: selected,
                        button: true,
                        label: category.label,
                        excludeSemantics: true,
                        onTap: () => onSelect(index),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            key: ValueKey('home_category_$index'),
                            onTap: () => onSelect(index),
                            borderRadius: BorderRadius.circular(19),
                            child: AnimatedContainer(
                              duration: duration,
                              curve: Curves.easeOutCubic,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: selected
                                    ? HomePalette.accent
                                    : palette.soft.withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(19),
                                boxShadow: selected
                                    ? [
                                        BoxShadow(
                                          color: HomePalette.accent.withValues(
                                            alpha: 0.28,
                                          ),
                                          blurRadius: 8,
                                          offset: const Offset(0, 2),
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    category.icon,
                                    size: 14,
                                    color: selected
                                        ? Colors.white
                                        : palette.muted,
                                  ),
                                  const SizedBox(width: 5),
                                  AnimatedDefaultTextStyle(
                                    duration: duration,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: selected
                                          ? Colors.white
                                          : palette.ink,
                                      letterSpacing: 0.2,
                                    ),
                                    child: Text(category.label),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Note: pinned header 必须把主题算进 shouldRebuild — 见
  // .agents/notes/implemented/bug-fix/2026-09-18-home-geometry-and-backup.md
  @override
  bool shouldRebuild(HomeTabBarDelegate oldDelegate) =>
      selectedIndex != oldDelegate.selectedIndex ||
      extent != oldDelegate.extent ||
      onSelect != oldDelegate.onSelect ||
      dark != oldDelegate.dark ||
      eink != oldDelegate.eink ||
      oled != oldDelegate.oled ||
      scroll != oldDelegate.scroll ||
      topInset != oldDelegate.topInset ||
      viewportWidth != oldDelegate.viewportWidth;
}

/// 吸顶后频道条要盖住底下滚过去的卡片，但它铺的纯画布会把页面顶部的暖光
/// 切断：吸顶条的顶边正好在状态栏下沿，上面还是一片红，段内却是纯画布。
///
/// 这里把背景层画的那段径向暖光按屏幕坐标重画一遍：吸顶条的顶边就是背景层
/// 的 [top]，水平方向再按 [viewportWidth] 减掉内容列的左边距，减完之后就是
/// 同一张渐变的下半段，边界自然接上。和背景层一样，画一次、之后只做平移，
/// 不逐帧重建渐变。
class HomePinnedWash extends StatelessWidget {
  final ScrollController scroll;
  final HomePalette palette;

  /// 吸顶条顶边在页面坐标里的位置（SafeArea 之后，通常等于状态栏高度）。
  final double top;

  /// 整页宽度；见 [HomeTabBarDelegate.viewportWidth]。
  final double viewportWidth;

  const HomePinnedWash({
    super.key,
    required this.scroll,
    required this.palette,
    required this.top,
    this.viewportWidth = 0,
  });

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: scroll,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _PinnedWashPainter(
                palette: palette,
                top: top,
                viewportWidth: viewportWidth,
              ),
            ),
          ),
          builder: (context, child) => Transform.translate(
            offset: Offset(0, reducedMotion ? 0 : -homeWashTravel(scroll)),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _PinnedWashPainter extends CustomPainter {
  final HomePalette palette;
  final double top;
  final double viewportWidth;

  const _PinnedWashPainter({
    required this.palette,
    required this.top,
    this.viewportWidth = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 背景层铺满整页，暖光圆心贴着**页面**右上角；吸顶条坐在居中的内容列
    // 里，宽度可能只有页面的一部分。几何统一按页面宽度推（见
    // [homePinnedWash]），否则平板/桌面下半径和圆心都偏，吸顶边上会错开。
    final wash = homePinnedWash(
      viewportWidth: viewportWidth,
      barWidth: size.width,
      top: top,
    );
    if (wash.radius <= 0) return;
    canvas.drawCircle(
      wash.center,
      wash.radius,
      Paint()
        ..shader = homeWashGradient(palette).createShader(
          Rect.fromCircle(center: wash.center, radius: wash.radius),
        ),
    );
  }

  @override
  bool shouldRepaint(_PinnedWashPainter oldDelegate) =>
      palette.dark != oldDelegate.palette.dark ||
      palette.oled != oldDelegate.palette.oled ||
      top != oldDelegate.top ||
      viewportWidth != oldDelegate.viewportWidth;
}
