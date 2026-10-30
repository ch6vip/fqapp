import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 顶栏：只有返回箭头（版式稿 `.bar`：44dp 高，左右 10dp）。
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
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
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
