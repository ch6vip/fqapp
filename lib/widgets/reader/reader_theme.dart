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

  /// The wash behind a text selection (long-pressed paragraph or a dragged
  /// handle range). The official reader tints its selection with the brand
  /// orange at 16% (`getHighlightColor` → `#FA6725`, alpha 41), identically
  /// across themes — replicated here instead of a per-preset tint.
  Color get selectionWashColor => const Color(0x29FA6725);

  /// The solid colour of the selection drag handles; official night theme
  /// drops the same orange to 60% (`b4e` `#99FA6725`).
  Color get selectionHandleColor =>
      isDark ? const Color(0x99FA6725) : const Color(0xFFFA6725);

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

  /// Built themes per preset, keyed by the base theme's identity. `fromSeed`
  /// runs a full HCT palette build and `textTheme.apply` copies ~90 text
  /// styles, and the reader calls this on every setState (selection drags,
  /// sliders re-run it per frame) — rebuilding identical instances each time
  /// is pure waste. The app's base theme is a constant instance between hot
  /// reloads, so an identity check recomputes only when it actually changes.
  static final Map<ReaderThemePreset, (ThemeData, ThemeData)> _themeCache = {};

  ThemeData theme(ThemeData base) {
    final cached = _themeCache[this];
    if (cached != null && identical(cached.$1, base)) return cached.$2;
    final built = _buildTheme(base);
    _themeCache[this] = (base, built);
    return built;
  }

  ThemeData _buildTheme(ThemeData base) {
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
