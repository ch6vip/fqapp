import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderThemePreset { light, eyeCare, parchment, dark }

@immutable
class ReaderPreferences {
  static const _fontSizeKey = 'reader_font_size';
  static const _fontWeightKey = 'reader_font_weight';
  static const _lineHeightKey = 'reader_line_height';
  static const _paragraphSpacingKey = 'reader_paragraph_spacing';
  static const _horizontalPaddingKey = 'reader_horizontal_padding';
  static const _themePresetKey = 'reader_theme_preset';

  final double fontSize;
  final int fontWeight;
  final double lineHeight;
  final double paragraphSpacing;
  final double horizontalPadding;
  final ReaderThemePreset themePreset;

  const ReaderPreferences({
    this.fontSize = 18,
    this.fontWeight = 400,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 12,
    this.horizontalPadding = 20,
    this.themePreset = ReaderThemePreset.light,
  });

  ReaderPreferences copyWith({
    double? fontSize,
    int? fontWeight,
    double? lineHeight,
    double? paragraphSpacing,
    double? horizontalPadding,
    ReaderThemePreset? themePreset,
  }) {
    return ReaderPreferences(
      fontSize: fontSize ?? this.fontSize,
      fontWeight: fontWeight ?? this.fontWeight,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      themePreset: themePreset ?? this.themePreset,
    ).normalized();
  }

  ReaderPreferences normalized() {
    final normalizedWeight = ((fontWeight.clamp(300, 700) / 100).round() * 100)
        .clamp(300, 700);
    return ReaderPreferences(
      fontSize: fontSize.isFinite ? fontSize.clamp(14, 32) : 18,
      fontWeight: normalizedWeight,
      lineHeight: lineHeight.isFinite ? lineHeight.clamp(1.2, 2.4) : 1.8,
      paragraphSpacing: paragraphSpacing.isFinite
          ? paragraphSpacing.clamp(0, 32)
          : 12,
      horizontalPadding: horizontalPadding.isFinite
          ? horizontalPadding.clamp(8, 48)
          : 20,
      themePreset: themePreset,
    );
  }

  static Future<ReaderPreferences> load() async {
    final preferences = await SharedPreferences.getInstance();
    final rawPreset = preferences.get(_themePresetKey);
    final preset = ReaderThemePreset.values.firstWhere(
      (value) => value.name == rawPreset,
      orElse: () => ReaderThemePreset.light,
    );
    return ReaderPreferences(
      fontSize: _number(preferences, _fontSizeKey) ?? 18,
      fontWeight: (_number(preferences, _fontWeightKey) ?? 400).round(),
      lineHeight: _number(preferences, _lineHeightKey) ?? 1.8,
      paragraphSpacing: _number(preferences, _paragraphSpacingKey) ?? 12,
      horizontalPadding: _number(preferences, _horizontalPaddingKey) ?? 20,
      themePreset: preset,
    ).normalized();
  }

  Future<void> save() async {
    final preferences = await SharedPreferences.getInstance();
    final value = normalized();
    await Future.wait<bool>([
      preferences.setDouble(_fontSizeKey, value.fontSize),
      preferences.setInt(_fontWeightKey, value.fontWeight),
      preferences.setDouble(_lineHeightKey, value.lineHeight),
      preferences.setDouble(_paragraphSpacingKey, value.paragraphSpacing),
      preferences.setDouble(_horizontalPaddingKey, value.horizontalPadding),
      preferences.setString(_themePresetKey, value.themePreset.name),
    ]);
  }

  static double? _number(SharedPreferences preferences, String key) {
    final value = preferences.get(key);
    return value is num && value.isFinite ? value.toDouble() : null;
  }
}
