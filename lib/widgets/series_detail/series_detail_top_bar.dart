import 'package:flutter/material.dart';

import '../home/home_back_button.dart';

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
    return SizedBox(
      key: const ValueKey('series-detail-topbar'),
      height: seriesDetailTopBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          // 版式稿的返回箭头是 Lucide chevron-left（36×36 点击区、20dp）；
          // HomeBackButton 就是同一几何，顺带统一 tooltip。
          child: HomeBackButton(
            key: const ValueKey('series-detail-back'),
            onPressed: onBack,
          ),
        ),
      ),
    );
  }
}
