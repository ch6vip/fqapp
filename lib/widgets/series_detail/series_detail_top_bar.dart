import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 顶栏高度（含上下 4dp 内边距）：版式稿 `.bar` 的 44dp 内容盒 + 上下各 4dp。
///
/// 页面用它算顶部色带高度（安全区顶 + 本值），色带正好在顶栏下缘淡出。
const double seriesDetailTopBarHeight = 52;

/// 顶栏：只有返回箭头（版式稿 `.bar`：内容 44dp、内边距 4/10、图标盒 36）。
///
/// 页面不显示剧名——滚动时也不显示，剧名只在头部出现一次。
class SeriesDetailTopBar extends StatelessWidget {
  const SeriesDetailTopBar({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      key: const ValueKey('series-detail-topbar'),
      height: seriesDetailTopBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            key: const ValueKey('series-detail-back'),
            tooltip: '返回',
            onPressed: onBack,
            iconSize: 20,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.arrow_back_ios_new_rounded, color: palette.ink),
          ),
        ),
      ),
    );
  }
}
