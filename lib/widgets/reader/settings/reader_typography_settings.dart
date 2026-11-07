import 'package:flutter/material.dart';

import '../../../services/reader_preferences.dart';
import '../reader_theme.dart';
import '../reader_value_slider.dart';
import 'reader_settings_widgets.dart';

enum ReaderTypographyCategory { all, font, paragraph, page }

typedef ReaderTypographySliderBuilder =
    Widget Function({
      required String id,
      required String label,
      required double current,
      required double min,
      required double max,
      required int divisions,
      required String Function(double) format,
      required ReaderPreferences Function(ReaderPreferences, double) apply,
    });

/// fqapp's typography limits and persistence with Wenku8 value controls.
/// The host decorates individual controls, keeping their layout during preview.
class ReaderTypographySettings extends StatelessWidget {
  const ReaderTypographySettings({
    super.key,
    required this.value,
    required this.onChanged,
    required this.backgroundLocked,
    this.category = ReaderTypographyCategory.all,
    this.sliderBuilder,
    this.decorate,
  });

  final ReaderPreferences value;
  final ValueChanged<ReaderPreferences> onChanged;
  final bool backgroundLocked;
  final ReaderTypographyCategory category;
  final ReaderTypographySliderBuilder? sliderBuilder;
  final Widget Function(Widget)? decorate;

  void _apply(ReaderPreferences Function(ReaderPreferences) change) =>
      onChanged(change(value));

  Widget _item(Widget child) => decorate?.call(child) ?? child;

  Widget _slider({
    required String id,
    required String label,
    required double current,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ReaderPreferences Function(ReaderPreferences, double) apply,
  }) {
    if (sliderBuilder case final builder?) {
      return builder(
        id: id,
        label: label,
        current: current,
        min: min,
        max: max,
        divisions: divisions,
        format: format,
        apply: apply,
      );
    }
    return ReaderValueSlider(
      sliderKey: ValueKey(id),
      label: label,
      value: current,
      min: min,
      max: max,
      divisions: divisions,
      format: format,
      onCommitted: (next) => _apply((prefs) => apply(prefs, next)),
    );
  }

  bool _shows(ReaderTypographyCategory target) =>
      category == ReaderTypographyCategory.all || category == target;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_shows(ReaderTypographyCategory.font)) ...[
        _slider(
          id: 'reader-font-size',
          label: '字号',
          current: value.fontSize,
          min: 14,
          max: 32,
          divisions: 18,
          format: (n) => '${n.round()} pt',
          apply: (prefs, n) => prefs.copyWith(fontSize: n),
        ),
        _item(_weightRow()),
        _slider(
          id: 'reader-letter-spacing',
          label: '字距',
          current: value.letterSpacing,
          min: -0.5,
          max: 3,
          divisions: 35,
          format: (n) => n.toStringAsFixed(1),
          apply: (prefs, n) => prefs.copyWith(letterSpacing: n),
        ),
        _slider(
          id: 'reader-title-size',
          label: '标题字号',
          current: value.titleSize,
          min: 16,
          max: 40,
          divisions: 24,
          format: (n) => '${n.round()} pt',
          apply: (prefs, n) => prefs.copyWith(titleSize: n),
        ),
        _item(_titleAlignmentRow()),
      ],
      if (_shows(ReaderTypographyCategory.paragraph)) ...[
        _slider(
          id: 'reader-line-height',
          label: '行距',
          current: value.lineHeight,
          min: 1.2,
          max: 2.4,
          divisions: 12,
          format: (n) => '${n.toStringAsFixed(1)} 倍',
          apply: (prefs, n) => prefs.copyWith(lineHeight: n),
        ),
        _slider(
          id: 'reader-paragraph-spacing',
          label: '段距',
          current: value.paragraphSpacing,
          min: 0,
          max: 32,
          divisions: 16,
          format: (n) => n.round().toString(),
          apply: (prefs, n) => prefs.copyWith(paragraphSpacing: n),
        ),
      ],
      if (_shows(ReaderTypographyCategory.page)) ...[
        _slider(
          id: 'reader-horizontal-padding',
          label: '左右边距',
          current: value.horizontalPadding,
          min: 8,
          max: 48,
          divisions: 20,
          format: (n) => n.round().toString(),
          apply: (prefs, n) => prefs.copyWith(horizontalPadding: n),
        ),
        _slider(
          id: 'reader-vertical-padding',
          label: '上下边距',
          current: value.verticalPadding,
          min: 0,
          max: 64,
          divisions: 16,
          format: (n) => n.round().toString(),
          apply: (prefs, n) => prefs.copyWith(verticalPadding: n),
        ),
      ],
      if (_shows(ReaderTypographyCategory.font)) _item(_restoreButton(context)),
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

  Widget _titleAlignmentRow() => ReaderSettingsRow(
    label: '标题对齐',
    child: ReaderSettingsChipRow(
      children: [
        for (final alignment in ReaderTitleAlignment.values)
          ReaderSettingsChip(
            key: ValueKey('reader-title-alignment-${alignment.name}'),
            label: alignment == ReaderTitleAlignment.start ? '居左' : '居中',
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
          onPressed: () => onChanged(
            ReaderPreferences(
              brightness: value.brightness,
              followSystemBrightness: value.followSystemBrightness,
              themePreset: backgroundLocked
                  ? value.themePreset
                  : const ReaderPreferences().themePreset,
            ),
          ),
          child: const Text('恢复默认排版', style: TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}
