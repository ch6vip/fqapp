import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../home/home_archive.dart';
import '../home/home_design.dart';

/// 搜索来源的「番茄 | 书旗」两段切换。
///
/// Bordered, shadow-free segments stay distinct from the category underline.
/// The full-height hit targets extend beyond the visible track.
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
      MediaQuery.textScalerOf(context).scale(12) * 1.2 + 4,
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
                border: Border.all(color: palette.line),
                borderRadius: BorderRadius.circular(homePanelRadius),
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
        borderRadius: BorderRadius.circular(homePanelRadius),
        child: SizedBox(
          height: tapHeight,
          child: Center(
            child: Container(
              height: segmentHeight,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? palette.ink : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? palette.canvas : palette.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
