import 'package:flutter/material.dart';

import 'home_design.dart';
import 'home_shelf.dart';

/// First-load skeleton, shaped like the shelf it is standing in for.
///
/// 首页改成「继续阅读一行字 / 榜单 / 书籍网格」之后，旧版照 `cmc.xml` 画的
/// 「白色区块 + 四行榜单」已经对不上真实版式：骨架屏价值在于让真卡片落位
/// 时不跳，形状错了反而更跳。这里只留一行字条、一个分区头、两行三列的书封。
class HomeSkeleton extends StatefulWidget {
  const HomeSkeleton({super.key});

  @override
  State<HomeSkeleton> createState() => _HomeSkeletonState();
}

class _HomeSkeletonState extends State<HomeSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect the OS "remove animations" setting: no pulse, just the shapes.
    final animate = !MediaQuery.disableAnimationsOf(context);
    final body = const Padding(
      padding: EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ContinueSkeleton(),
          Padding(
            padding: EdgeInsets.fromLTRB(
              homeGutter,
              homeSectionGap,
              homeGutter,
              homeHeaderGap,
            ),
            child: _Bar(width: 96, height: 18, radius: 4),
          ),
          _GridSkeleton(),
        ],
      ),
    );
    if (!animate) return body;
    return FadeTransition(
      // 0.6 -> 1.0：官方 SkeletonLayout 的呼吸透明度。
      opacity: Tween<double>(
        begin: 0.6,
        end: 1,
      ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: body,
    );
  }
}

/// 「继续阅读」那一行字：左侧动作 + 一条书名。
class _ContinueSkeleton extends StatelessWidget {
  const _ContinueSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(homeGutter, 10, homeGutter, 10),
      child: Row(
        children: [
          _Bar(width: 52, height: 11, radius: 4),
          SizedBox(width: 8),
          Expanded(child: _Bar(height: 12, radius: 4)),
        ],
      ),
    );
  }
}

/// 两行三列的书封，与真网格的 5:7 比例、12dp 列距一致。
class _GridSkeleton extends StatelessWidget {
  const _GridSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      child: Column(
        children: [
          for (var row = 0; row < 2; row++) ...[
            if (row > 0) const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var column = 0; column < 3; column++) ...[
                  if (column > 0) const SizedBox(width: homeGridGap),
                  const Expanded(child: _CardSkeleton()),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(aspectRatio: 5 / 7, child: _Bar(radius: 12)),
        SizedBox(height: 8),
        _Bar(height: 14, radius: 4),
        SizedBox(height: 6),
        FractionallySizedBox(
          widthFactor: 0.55,
          alignment: Alignment.centerLeft,
          child: _Bar(height: 14, radius: 4),
        ),
        SizedBox(height: 6),
        FractionallySizedBox(
          widthFactor: 0.4,
          alignment: Alignment.centerLeft,
          child: _Bar(height: 10, radius: 4),
        ),
      ],
    );
  }
}

/// One placeholder bar. Colour comes from the palette so the skeleton sits on
/// the canvas and on OLED the same way the real cards do.
class _Bar extends StatelessWidget {
  const _Bar({this.height, this.width, this.radius = 3});

  final double? height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
