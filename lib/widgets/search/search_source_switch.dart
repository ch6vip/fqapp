import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 搜索来源的「番茄 | 书旗」两段切换。
///
/// 外框 32 高、内边距 2、圆角 16、[HomePalette.soft] 底；每段 28 高、
/// 水平内边距 11、13sp。选中段浅色用 [HomePalette.surface]，深色用
/// [HomePalette.line]，文字 ink、w700，并带一层轻阴影；未选中段 muted、
/// w500。点击区纵向撑满整条范围条，不只限于 28 高的胶囊。
class SearchSourceSwitch extends StatelessWidget {
  static const double defaultTapHeight = 48;
  static const double trackHeight = 32;
  static const double segmentHeight = 28;

  final bool shuqi;

  /// 点击区高度；传入范围条高度让两段都能在整条上点中。
  final double tapHeight;

  final ValueChanged<bool> onChanged;

  const SearchSourceSwitch({
    super.key,
    required this.shuqi,
    required this.onChanged,
    this.tapHeight = defaultTapHeight,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // 默认字号下就是样稿的 28 / 32；大字体时随文字长高，避免 13sp 被裁掉。
    final segmentHeight = math.max(
      SearchSourceSwitch.segmentHeight,
      MediaQuery.textScalerOf(context).scale(13) * 1.2,
    );
    final trackHeight = segmentHeight + 4;
    return SizedBox(
      height: tapHeight,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: (tapHeight - trackHeight) / 2,
            height: trackHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: palette.soft,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _segment(
                  context,
                  palette,
                  key: const Key('search-source-fanqie'),
                  label: '番茄',
                  selected: !shuqi,
                  segmentHeight: segmentHeight,
                  onTap: () => onChanged(false),
                ),
                _segment(
                  context,
                  palette,
                  key: const Key('search-shuqi-source'),
                  label: '书旗',
                  selected: shuqi,
                  segmentHeight: segmentHeight,
                  onTap: () => onChanged(true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    HomePalette palette, {
    required Key key,
    required String label,
    required bool selected,
    required double segmentHeight,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: tapHeight,
          child: Center(
            child: Container(
              height: segmentHeight,
              padding: const EdgeInsets.symmetric(horizontal: 11),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? (palette.dark ? palette.line : palette.surface)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? palette.ink : palette.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
