import 'package:flutter/material.dart';

import '../../../services/reader_preferences.dart';
import '../reader_theme.dart';
import 'reader_settings_widgets.dart';

/// 「更多设置 · 排版」分组：字重、行距、段距、边距、字距、标题与恢复默认。
///
/// 单独成文件，避免设置面板主文件继续膨胀；所有改动都走 [onChanged]，
/// 由面板统一做 120ms 合并。
class ReaderTypographySettings extends StatelessWidget {
  const ReaderTypographySettings({
    super.key,
    required this.value,
    required this.onChanged,
    required this.backgroundLocked,
  });

  final ReaderPreferences value;
  final ValueChanged<ReaderPreferences> onChanged;

  /// 全局墨水屏 / OLED 接管背景时，恢复默认不能悄悄改掉保存的预设。
  final bool backgroundLocked;

  void _apply(ReaderPreferences Function(ReaderPreferences) change) =>
      onChanged(change(value));

  void _step({
    required double current,
    required double delta,
    required double min,
    required double max,
    required ReaderPreferences Function(ReaderPreferences, double) apply,
  }) {
    final next = (current + delta).clamp(min, max).toDouble();
    _apply((prefs) => apply(prefs, next));
  }

  /// 恢复默认排版：保留亮度与跟随系统；背景被全局模式接管时，也保留用户
  /// 已保存的预设，关闭全局模式后仍回到原来那套背景。
  void _restoreDefaults() {
    onChanged(
      ReaderPreferences(
        brightness: value.brightness,
        followSystemBrightness: value.followSystemBrightness,
        themePreset: backgroundLocked
            ? value.themePreset
            : const ReaderPreferences().themePreset,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _weightRow(),
      _lineHeightRow(),
      _paragraphSpacingRow(),
      _horizontalPaddingRow(),
      _verticalPaddingRow(),
      _letterSpacingRow(),
      _titleSizeRow(),
      _titleAlignmentRow(),
      _restoreButton(context),
    ],
  );

  Widget _weightRow() => ReaderSettingsRow(
    label: '字重',
    child: ReaderSettingsChipRow(
      children: [
        for (final entry in const {
          300: '细',
          400: '标准',
          500: '适中',
          600: '偏粗',
          700: '粗',
        }.entries)
          ReaderSettingsChip(
            key: ValueKey('reader-font-weight-${entry.key}'),
            label: entry.value,
            selected: value.fontWeight == entry.key,
            onTap: () =>
                _apply((prefs) => prefs.copyWith(fontWeight: entry.key)),
          ),
      ],
    ),
  );

  Widget _lineHeightRow() => ReaderSettingsRow(
    label: '行距',
    child: ReaderSettingsStepper(
      key: const ValueKey('reader-line-height'),
      value: value.lineHeight.toStringAsFixed(1),
      decreaseTooltip: '减小行距',
      increaseTooltip: '增大行距',
      onDecrease: value.lineHeight > 1.2
          ? () => _step(
              current: value.lineHeight,
              delta: -0.1,
              min: 1.2,
              max: 2.4,
              apply: (prefs, next) => prefs.copyWith(lineHeight: next),
            )
          : null,
      onIncrease: value.lineHeight < 2.4
          ? () => _step(
              current: value.lineHeight,
              delta: 0.1,
              min: 1.2,
              max: 2.4,
              apply: (prefs, next) => prefs.copyWith(lineHeight: next),
            )
          : null,
    ),
  );

  Widget _paragraphSpacingRow() => ReaderSettingsRow(
    label: '段距',
    child: ReaderSettingsStepper(
      value: value.paragraphSpacing.round().toString(),
      decreaseTooltip: '减小段距',
      increaseTooltip: '增大段距',
      onDecrease: value.paragraphSpacing > 0
          ? () => _step(
              current: value.paragraphSpacing,
              delta: -2,
              min: 0,
              max: 32,
              apply: (prefs, next) => prefs.copyWith(paragraphSpacing: next),
            )
          : null,
      onIncrease: value.paragraphSpacing < 32
          ? () => _step(
              current: value.paragraphSpacing,
              delta: 2,
              min: 0,
              max: 32,
              apply: (prefs, next) => prefs.copyWith(paragraphSpacing: next),
            )
          : null,
    ),
  );

  Widget _horizontalPaddingRow() => ReaderSettingsRow(
    label: '左右边距',
    child: ReaderSettingsStepper(
      value: value.horizontalPadding.round().toString(),
      decreaseTooltip: '减小左右边距',
      increaseTooltip: '增大左右边距',
      onDecrease: value.horizontalPadding > 8
          ? () => _step(
              current: value.horizontalPadding,
              delta: -2,
              min: 8,
              max: 48,
              apply: (prefs, next) => prefs.copyWith(horizontalPadding: next),
            )
          : null,
      onIncrease: value.horizontalPadding < 48
          ? () => _step(
              current: value.horizontalPadding,
              delta: 2,
              min: 8,
              max: 48,
              apply: (prefs, next) => prefs.copyWith(horizontalPadding: next),
            )
          : null,
    ),
  );

  Widget _verticalPaddingRow() => ReaderSettingsRow(
    label: '上下边距',
    child: ReaderSettingsStepper(
      value: value.verticalPadding.round().toString(),
      decreaseTooltip: '减小上下边距',
      increaseTooltip: '增大上下边距',
      onDecrease: value.verticalPadding > 0
          ? () => _step(
              current: value.verticalPadding,
              delta: -4,
              min: 0,
              max: 64,
              apply: (prefs, next) => prefs.copyWith(verticalPadding: next),
            )
          : null,
      onIncrease: value.verticalPadding < 64
          ? () => _step(
              current: value.verticalPadding,
              delta: 4,
              min: 0,
              max: 64,
              apply: (prefs, next) => prefs.copyWith(verticalPadding: next),
            )
          : null,
    ),
  );

  Widget _letterSpacingRow() => ReaderSettingsRow(
    label: '字距',
    child: ReaderSettingsStepper(
      value: value.letterSpacing.toStringAsFixed(1),
      decreaseTooltip: '减小字距',
      increaseTooltip: '增大字距',
      onDecrease: value.letterSpacing > -0.5
          ? () => _step(
              current: value.letterSpacing,
              delta: -0.1,
              min: -0.5,
              max: 3,
              apply: (prefs, next) => prefs.copyWith(letterSpacing: next),
            )
          : null,
      onIncrease: value.letterSpacing < 3
          ? () => _step(
              current: value.letterSpacing,
              delta: 0.1,
              min: -0.5,
              max: 3,
              apply: (prefs, next) => prefs.copyWith(letterSpacing: next),
            )
          : null,
    ),
  );

  Widget _titleSizeRow() => ReaderSettingsRow(
    label: '标题字号',
    child: ReaderSettingsStepper(
      value: value.titleSize.round().toString(),
      decreaseTooltip: '减小标题字号',
      increaseTooltip: '增大标题字号',
      onDecrease: value.titleSize > 16
          ? () => _step(
              current: value.titleSize,
              delta: -1,
              min: 16,
              max: 40,
              apply: (prefs, next) => prefs.copyWith(titleSize: next),
            )
          : null,
      onIncrease: value.titleSize < 40
          ? () => _step(
              current: value.titleSize,
              delta: 1,
              min: 16,
              max: 40,
              apply: (prefs, next) => prefs.copyWith(titleSize: next),
            )
          : null,
    ),
  );

  Widget _titleAlignmentRow() => ReaderSettingsRow(
    label: '标题对齐',
    child: ReaderSettingsChipRow(
      children: [
        for (final alignment in ReaderTitleAlignment.values)
          ReaderSettingsChip(
            key: ValueKey('reader-title-alignment-${alignment.name}'),
            label: alignment == ReaderTitleAlignment.start ? '标题居左' : '标题居中',
            selected: value.titleAlignment == alignment,
            onTap: () =>
                _apply((prefs) => prefs.copyWith(titleAlignment: alignment)),
          ),
      ],
    ),
  );

  Widget _restoreButton(BuildContext context) {
    final preset = ReaderSettingsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Center(
        child: TextButton(
          key: const ValueKey('reader-restore-defaults'),
          style: TextButton.styleFrom(
            backgroundColor: preset.fieldColor,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            minimumSize: const Size(0, 32),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
          ),
          onPressed: _restoreDefaults,
          child: const Text('恢复默认排版', style: TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}
