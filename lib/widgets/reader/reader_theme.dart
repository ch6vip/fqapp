import 'package:flutter/material.dart';

import '../../services/app_theme.dart';
import '../../services/reader_preferences.dart';

extension ReaderThemeColors on ReaderThemePreset {
  bool get isDark => this == ReaderThemePreset.dark;

  /// #15/#9 墨水屏：纯黑白，不走任何色调推导，墨水屏量化时不产生灰阶。
  bool get isEink => this == ReaderThemePreset.eink;

  /// 全局 OLED 纯黑：只给夜间底色降为 #000000 省电，面板 / 字段仍用近黑
  /// + 描边，避免纯黑把正文、弹层边界一起吞掉。只在深色外观下生效；
  /// 生效时阅读页被强制到夜间预设（见 reader_page 的 _effectivePreset），
  /// 与墨水屏一致。
  bool get isOled => isDark && oledActive();

  String get label => switch (this) {
    ReaderThemePreset.light => '米白',
    ReaderThemePreset.eyeCare => '青绿',
    ReaderThemePreset.parchment => '纸张',
    ReaderThemePreset.dark => '夜间',
    ReaderThemePreset.eink => '墨水屏',
  };

  Color get backgroundColor => switch (this) {
    ReaderThemePreset.light => const Color(0xFFFAF9F6),
    ReaderThemePreset.eyeCare => const Color(0xFFE8F1DF),
    ReaderThemePreset.parchment => const Color(0xFFF3E4C2),
    ReaderThemePreset.dark => isOled ? Colors.black : const Color(0xFF171717),
    ReaderThemePreset.eink => Colors.white,
  };

  Color get textColor => switch (this) {
    ReaderThemePreset.light => const Color(0xFF292724),
    ReaderThemePreset.eyeCare => const Color(0xFF273128),
    ReaderThemePreset.parchment => const Color(0xFF493D2B),
    ReaderThemePreset.dark => const Color(0xFFD2D2D2),
    ReaderThemePreset.eink => Colors.black,
  };

  Color get accentColor => switch (this) {
    ReaderThemePreset.eyeCare => const Color(0xFF4F6F52),
    ReaderThemePreset.dark => const Color(0xFFE9AD82),
    ReaderThemePreset.eink => Colors.black,
    _ => const Color(0xFF9B6743),
  };

  Color get mutedTextColor {
    if (isEink) return Colors.black;
    // 纯黑底上 60% 的前景色只剩 #7E7E7E，12sp 提示字偏灰；OLED 用固定值。
    if (isOled) return const Color(0xFF9E9A94);
    return textColor.withValues(alpha: 0.6);
  }

  /// 官方每个阅读主题一个选区强调色(un4.j.t / ReaderCommonColor.getHighlightColor
  /// 的 b4e-b4i 资源表):light #FA6725、parchment(纸) #CC8114、eyeCare(绿)
  /// #65992E;官方另有蓝色主题 #3D85CC,我们暂无对应预设。夜间走同一橙。
  Color get selectionAccentColor => switch (this) {
    ReaderThemePreset.parchment => const Color(0xFFCC8114),
    ReaderThemePreset.eyeCare => const Color(0xFF65992E),
    ReaderThemePreset.eink => Colors.black,
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

  /// 朗读句高亮底色：与选区强调色区分开的暖黄，墨水屏用淡黑灰以免
  /// 盖住正文。
  Color get narrationHighlightColor => isEink
      ? Colors.black.withValues(alpha: 0.10)
      : const Color(0xFFFFC107).withValues(alpha: 0.28);

  Color get panelColor {
    if (isEink) return Colors.white;
    // OLED：纯黑页面上的浮层必须比底色亮一档，否则面板边界消失。
    if (isOled) return const Color(0xFF0C0C0E);
    return Color.alphaBlend(
      isDark ? const Color(0x0DFFFFFF) : const Color(0x99FFFFFF),
      backgroundColor,
    );
  }

  Color get fieldColor {
    if (isEink) return Colors.white;
    if (isOled) return const Color(0xFF141417);
    return Color.alphaBlend(
      textColor.withValues(alpha: isDark ? 0.06 : 0.035),
      panelColor,
    );
  }

  Color get borderColor {
    if (isEink) return Colors.black;
    if (isOled) return const Color(0xFF2E2E34);
    return textColor.withValues(alpha: 0.09);
  }
  /// 排版面板表面 = 阅读页背景本身(官方 bottombar/t.java 直接把面板根
  /// View 设为 readerConfig.getBackgroundColor(),面板与页面同色);chip/
  /// 控件底色另走 fieldColor(官方是白色 5% 叠加,x4 色表)。
  /// OLED 例外：页面是 #000000 时面板也铺黑就分不清边界了，改取近黑档，
  /// 与 theme() 的 bottomSheetTheme 保持一致。
  Color get sheetColor => isOled ? panelColor : backgroundColor;

  /// Built themes per preset, keyed by the base theme's identity. `fromSeed`
  /// runs a full HCT palette build and `textTheme.apply` copies ~90 text
  /// styles, and the reader calls this on every setState (selection drags,
  /// sliders re-run it per frame) — rebuilding identical instances each time
  /// is pure waste. The app's base theme is a constant instance between hot
  /// reloads, so an identity check recomputes only when it actually changes.
  static final Map<(ReaderThemePreset, bool), (ThemeData, ThemeData)>
  _themeCache = {};

  ThemeData theme(ThemeData base) {
    // OLED 开关会改变色板，缓存键必须带上它，否则关灯后仍拿旧主题。
    final key = (this, isOled);
    final cached = _themeCache[key];
    if (cached != null && identical(cached.$1, base)) return cached.$2;
    final built = _buildTheme(base);
    _themeCache[key] = (base, built);
    return built;
  }

  ThemeData _buildTheme(ThemeData base) {
    // 墨水屏不走 fromSeed：HCT 色调推导会产生大量灰阶，在墨水屏上被量化
    // 成抖动/残影。直接给纯黑白 ColorScheme。
    final scheme = isEink
        ? const ColorScheme(
            brightness: Brightness.light,
            primary: Colors.black,
            onPrimary: Colors.white,
            primaryContainer: Colors.white,
            onPrimaryContainer: Colors.black,
            secondary: Colors.black,
            onSecondary: Colors.white,
            secondaryContainer: Colors.white,
            onSecondaryContainer: Colors.black,
            tertiary: Colors.black,
            onTertiary: Colors.white,
            surface: Colors.white,
            onSurface: Colors.black,
            surfaceContainerLowest: Colors.white,
            surfaceContainerLow: Colors.white,
            surfaceContainer: Colors.white,
            surfaceContainerHigh: Colors.white,
            surfaceContainerHighest: Colors.white,
            onSurfaceVariant: Colors.black,
            outline: Colors.black,
            outlineVariant: Colors.black,
            error: Colors.black,
            onError: Colors.white,
            errorContainer: Colors.white,
            onErrorContainer: Colors.black,
          )
        : ColorScheme.fromSeed(
            seedColor: accentColor,
            brightness: isDark ? Brightness.dark : Brightness.light,
          ).copyWith(
            primary: accentColor,
            onPrimary: isDark ? backgroundColor : Colors.white,
            surface: panelColor,
            onSurface: textColor,
            onSurfaceVariant: mutedTextColor,
            // OLED：种子推导出的棕灰在纯黑上会发亮；表面层次换成与全局
            // OLED 色板一致的近黑档，弹层 / 插图占位不再冒出一块暖灰。
            surfaceContainerLowest: isOled ? Colors.black : null,
            surfaceContainerLow: isOled ? const Color(0xFF0C0C0E) : null,
            surfaceContainer: isOled ? const Color(0xFF121215) : null,
            surfaceContainerHigh: isOled ? const Color(0xFF17171A) : null,
            surfaceContainerHighest: isOled
                ? const Color(0xFF1F1F23)
                : null,
            outlineVariant: isOled ? const Color(0xFF2E2E34) : null,
          );
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: backgroundColor,
      textTheme: base.textTheme.apply(
        bodyColor: textColor,
        displayColor: textColor,
      ),
      // Note: AppTheme fixes ListTile text colours explicitly; changing only
      // colorScheme leaves light-app/dark-reader chapter titles dark on dark.
      // See .agents/notes/implemented/bug-fix/2026-10-15-reader-directory-theme.md.
      listTileTheme: base.listTileTheme.copyWith(
        textColor: textColor,
        iconColor: mutedTextColor,
        selectedColor: accentColor,
        titleTextStyle: (base.listTileTheme.titleTextStyle ?? const TextStyle())
            .copyWith(color: textColor),
        subtitleTextStyle:
            (base.listTileTheme.subtitleTextStyle ?? const TextStyle())
                .copyWith(color: mutedTextColor),
      ),
      iconTheme: base.iconTheme.copyWith(color: mutedTextColor),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: fieldColor,
        hintStyle: TextStyle(color: mutedTextColor),
        prefixIconColor: mutedTextColor,
        suffixIconColor: mutedTextColor,
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
