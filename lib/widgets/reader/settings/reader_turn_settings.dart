import 'package:flutter/material.dart';

import '../../../services/reader_preferences.dart';
import '../reader_scroll_mode_setting.dart';
import 'reader_settings_widgets.dart';

/// 翻页与滚动跨章共用上游设置行；分页时不显示跨章选项。
class ReaderTurnSettings extends StatelessWidget {
  const ReaderTurnSettings({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ReaderPreferences value;
  final ValueChanged<ReaderPreferences> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _turnRow(),
      if (value.pageMode == ReaderPageMode.scroll)
        ReaderScrollModeSetting(
          value: value.scrollChapterMode,
          onChanged: (mode) =>
              onChanged(value.copyWith(scrollChapterMode: mode)),
        ),
    ],
  );

  Widget _turnRow() {
    final paged =
        value.pageMode == ReaderPageMode.paged && !value.instantSwipeTurn;
    bool style(ReaderPageTurnStyle style) =>
        paged && value.pageTurnStyle == style;
    return ReaderSettingsRow(
      label: '翻页',
      child: ReaderSettingsChipRow(
        children: [
          ReaderSettingsChip(
            key: const ValueKey('reader-turn-curl'),
            label: '仿真',
            selected: style(ReaderPageTurnStyle.curl),
            onTap: () => _selectPagedStyle(ReaderPageTurnStyle.curl),
          ),
          ReaderSettingsChip(
            key: const ValueKey('reader-mode-paged'),
            label: '覆盖',
            selected: style(ReaderPageTurnStyle.cover),
            onTap: () => _selectPagedStyle(ReaderPageTurnStyle.cover),
          ),
          ReaderSettingsChip(
            key: const ValueKey('reader-turn-slide'),
            label: '平移',
            selected: style(ReaderPageTurnStyle.slide),
            onTap: () => _selectPagedStyle(ReaderPageTurnStyle.slide),
          ),
          ReaderSettingsChip(
            key: const ValueKey('reader-mode-scroll'),
            label: '滚动',
            selected: value.pageMode == ReaderPageMode.scroll,
            onTap: () =>
                onChanged(value.copyWith(pageMode: ReaderPageMode.scroll)),
          ),
        ],
      ),
    );
  }

  /// 选具体翻页方式即回到分页模式，并关掉「无动画翻页」。
  void _selectPagedStyle(ReaderPageTurnStyle style) => onChanged(
    value.copyWith(
      pageMode: ReaderPageMode.paged,
      pageTurnStyle: style,
      instantSwipeTurn: false,
    ),
  );
}
