import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 顶栏：静止时只有返回箭头，滚过头部后淡入剧名（官方
/// `VideoCommonTitleBar` 初始 gone 的行为）。背景透出页面色带。
class SeriesDetailTopBar extends StatelessWidget {
  const SeriesDetailTopBar({
    super.key,
    required this.title,
    required this.revealed,
    required this.onBack,
  });

  final String title;
  final bool revealed;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      key: const ValueKey('series-detail-topbar'),
      height: 44,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('series-detail-back'),
            tooltip: '返回',
            onPressed: onBack,
            icon: Icon(Icons.arrow_back_ios_new_rounded, color: palette.ink),
          ),
          Expanded(
            child: AnimatedOpacity(
              opacity: revealed ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Text(
                title,
                key: const ValueKey('series-detail-topbar-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
