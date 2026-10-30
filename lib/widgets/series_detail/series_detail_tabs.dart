import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 吸顶导航：40dp 钉在顶栏下，滚过头部后垫上与色带完全一致的不透明底，
/// 内容从字下穿过也不会出现横条。
class SeriesDetailTabsDelegate extends SliverPersistentHeaderDelegate {
  const SeriesDetailTabsDelegate({
    required this.names,
    required this.height,
    required this.activeIndex,
    required this.pinned,
    required this.background,
    required this.onTap,
  });

  final List<String> names;
  final double height;
  final int activeIndex;
  final bool pinned;

  /// 未吸顶时为 null（透出页面色带），吸顶后由页面算好与背景一致的底。
  final BoxDecoration? background;
  final ValueChanged<int> onTap;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final palette = HomePalette.of(context);
    return Container(
      key: const ValueKey('series-detail-tabs'),
      height: height,
      decoration: pinned ? background : null,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
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
                        color: i == activeIndex ? palette.ink : palette.muted,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(SeriesDetailTabsDelegate oldDelegate) =>
      oldDelegate.height != height ||
      oldDelegate.activeIndex != activeIndex ||
      oldDelegate.pinned != pinned ||
      oldDelegate.background != background ||
      oldDelegate.names.length != names.length;
}
