import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import 'settings/reader_settings_widgets.dart';

class ReaderScrollModeSetting extends StatelessWidget {
  const ReaderScrollModeSetting({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ReaderScrollChapterMode value;
  final ValueChanged<ReaderScrollChapterMode> onChanged;

  @override
  Widget build(BuildContext context) => ReaderSettingsRow(
    key: const ValueKey('reader-scroll-chapter-mode'),
    label: '跨章',
    child: ReaderSettingsChipRow(
      children: [
        for (final mode in const [
          ReaderScrollChapterMode.joined,
          ReaderScrollChapterMode.replace,
        ])
          ReaderSettingsChip(
            key: ValueKey('reader-cross-chapter-${mode.name}'),
            label: mode == ReaderScrollChapterMode.joined ? '分割线拼接' : '直接切换',
            selected: value == mode,
            onTap: () => onChanged(mode),
          ),
      ],
    ),
  );
}
