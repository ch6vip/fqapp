import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';

extension ReaderThemeColors on ReaderThemePreset {
  bool get isDark => this == ReaderThemePreset.dark;

  String get label => switch (this) {
    ReaderThemePreset.light => '米白',
    ReaderThemePreset.eyeCare => '青绿',
    ReaderThemePreset.parchment => '纸张',
    ReaderThemePreset.dark => '夜间',
  };

  Color get backgroundColor => switch (this) {
    ReaderThemePreset.light => const Color(0xFFFAF9F6),
    ReaderThemePreset.eyeCare => const Color(0xFFE8F1DF),
    ReaderThemePreset.parchment => const Color(0xFFF3E4C2),
    ReaderThemePreset.dark => const Color(0xFF171717),
  };

  Color get textColor => switch (this) {
    ReaderThemePreset.light => const Color(0xFF292724),
    ReaderThemePreset.eyeCare => const Color(0xFF273128),
    ReaderThemePreset.parchment => const Color(0xFF493D2B),
    ReaderThemePreset.dark => const Color(0xFFD2D2D2),
  };

  Color get accentColor => switch (this) {
    ReaderThemePreset.eyeCare => const Color(0xFF4F6F52),
    ReaderThemePreset.dark => const Color(0xFFE9AD82),
    _ => const Color(0xFF9B6743),
  };

  Color get mutedTextColor => textColor.withValues(alpha: 0.6);

  /// The wash behind a long-pressed paragraph while the action bar is up. The
  /// official engine paints its SelectionParagraph colour inside the native
  /// text layout with no resource to copy, so this is the body colour at a low
  /// alpha — a neutral that stays visible on all four presets.
  Color get selectionHighlightColor =>
      textColor.withValues(alpha: isDark ? 0.2 : 0.14);

  Color get panelColor => Color.alphaBlend(
    isDark ? const Color(0x0DFFFFFF) : const Color(0x99FFFFFF),
    backgroundColor,
  );
  Color get fieldColor => Color.alphaBlend(
    textColor.withValues(alpha: isDark ? 0.06 : 0.035),
    panelColor,
  );
  Color get borderColor => textColor.withValues(alpha: 0.09);
  Color get sheetColor => panelColor;

  ThemeData theme(ThemeData base) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accentColor,
          brightness: isDark ? Brightness.dark : Brightness.light,
        ).copyWith(
          primary: accentColor,
          onPrimary: isDark ? backgroundColor : Colors.white,
          surface: panelColor,
          onSurface: textColor,
          onSurfaceVariant: mutedTextColor,
        );
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: backgroundColor,
      textTheme: base.textTheme.apply(
        bodyColor: textColor,
        displayColor: textColor,
      ),
      dividerColor: borderColor,
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: accentColor,
        inactiveTrackColor: borderColor,
        thumbColor: accentColor,
        overlayColor: accentColor.withValues(alpha: 0.12),
        trackHeight: 3,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: panelColor,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: mutedTextColor.withValues(alpha: 0.3),
      ),
    );
  }
}
