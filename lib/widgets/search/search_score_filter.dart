import 'package:flutter/cupertino.dart';

import '../wenku/wenku_ui.dart';

/// fqapp-only rating filter on the results heading. Upstream has no rating
/// data; the control reuses its compact `GlassTextButton` and steps through
/// the offered thresholds instead of opening a Material dropdown.
class SearchScoreFilter extends StatelessWidget {
  static const thresholds = <double>[0, 8, 9];

  final bool enabled;
  final double minimumScore;
  final ValueChanged<double> onChanged;

  const SearchScoreFilter({
    super.key,
    required this.enabled,
    required this.minimumScore,
    required this.onChanged,
  });

  static String labelFor(double value) =>
      value == 0 ? '评分不限' : '${value.toStringAsFixed(0)} 分以上';

  @override
  Widget build(BuildContext context) {
    final value = enabled ? minimumScore : 0.0;
    final index = thresholds.indexOf(value);
    final next = thresholds[(index + 1) % thresholds.length];
    return Semantics(
      container: true,
      label: '评分筛选',
      value: labelFor(value),
      hint: enabled ? '切换为${labelFor(next)}' : null,
      child: GlassTextButton(
        key: const Key('search-minimum-score'),
        compact: true,
        selected: value > 0,
        onPressed: enabled ? () => onChanged(next) : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ArchiveIcon(
              CupertinoIcons.line_horizontal_3_decrease,
              size: 15,
            ),
            const SizedBox(width: 5),
            AppText(labelFor(value), style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
