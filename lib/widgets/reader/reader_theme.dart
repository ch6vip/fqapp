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

  /// 官方每个阅读主题一个选区强调色(un4.j.t / ReaderCommonColor.getHighlightColor
  /// 的 b4e-b4i 资源表):light #FA6725、parchment(纸) #CC8114、eyeCare(绿)
  /// #65992E;官方另有蓝色主题 #3D85CC,我们暂无对应预设。夜间走同一橙。
  Color get selectionAccentColor => switch (this) {
    ReaderThemePreset.parchment => const Color(0xFFCC8114),
    ReaderThemePreset.eyeCare => const Color(0xFF65992E),
    _ => const Color(0xFFFA6725),
  };

  /// The wash behind a text selection. 官方 markingConfig.b()(ReaderViewLayout
  /// 的 ie5.a 实现)= un4.j.C(theme, 0.16f) —— 强调色 @ 16%,C 会整体重设
  /// alpha,所以夜间也是 16% 橙。
  Color get selectionWashColor =>
      selectionAccentColor.withValues(alpha: 0.16);

  /// 控点实色(un4.j.t):夜间降到 60% 的橙,其余主题用强调色原色。
  Color get selectionHandleColor =>
      isDark ? const Color(0x99FA6725) : selectionAccentColor;

  /// 划线下划线 = 强调色实色(官方 markingConfig.d() = un4.j.B(theme)),
  /// 不是正文色;夜间自带 60% alpha。
  Color get selectionUnderlineColor => selectionHandleColor;

  Color get panelColor => Color.alphaBlend(
    isDark ? const Color(0x0DFFFFFF) : const Color(0x99FFFFFF),
    backgroundColor,
  );
  Color get fieldColor => Color.alphaBlend(
    textColor.withValues(alpha: isDark ? 0.06 : 0.035),
    panelColor,
  );
  Color get borderColor => textColor.withValues(alpha: 0.09);
  /// 排版面板表面 = 阅读页背景本身(官方 bottombar/t.java 直接把面板根
  /// View 设为 readerConfig.getBackgroundColor(),面板与页面同色);chip/
  /// 控件底色另走 fieldColor(官方是白色 5% 叠加,x4 色表)。
  Color get sheetColor => backgroundColor;

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
