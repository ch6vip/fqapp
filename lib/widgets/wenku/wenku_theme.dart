import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/app_theme.dart';
import 'src/performance_preferences.dart';
import 'wenku_archive.dart';

abstract final class WenkuMotion {
  static const contact = Duration(milliseconds: 120);
  static const enter = Duration(milliseconds: 420);
  static const exit = Duration(milliseconds: 320);
  static const ease = Curves.easeOutCubic;
  static const retract = Curves.easeInCubic;
  static const settle = Cubic(.2, 1.08, .34, 1);
  static const spring = SpringDescription(
    mass: .64,
    stiffness: 270,
    damping: 19,
  );
}

/// The archive uses a neutral palette instead of fqapp's orange product accent.
/// The surrounding app keeps its own theme; this extension only changes the
/// ported Wenku8 surfaces below [WenkuScope].
@immutable
class WenkuAppearance extends ThemeExtension<WenkuAppearance> {
  const WenkuAppearance({
    required this.eink,
    required this.oled,
    required this.highContrast,
  });

  final bool eink;
  final bool oled;
  final bool highContrast;

  @override
  WenkuAppearance copyWith({bool? eink, bool? oled, bool? highContrast}) =>
      WenkuAppearance(
        eink: eink ?? this.eink,
        oled: oled ?? this.oled,
        highContrast: highContrast ?? this.highContrast,
      );

  @override
  WenkuAppearance lerp(WenkuAppearance? other, double t) => other == null
      ? this
      : WenkuAppearance(
          eink: t < .5 ? eink : other.eink,
          oled: t < .5 ? oled : other.oled,
          highContrast: t < .5 ? highContrast : other.highContrast,
        );
}

/// A small, interpolated set of archive/glass colors. Classic values reproduce
/// the upstream milk/stone palette exactly.
@immutable
class WenkuTonalColors extends ThemeExtension<WenkuTonalColors> {
  const WenkuTonalColors({
    required this.pageStart,
    required this.pageEnd,
    required this.milk,
    required this.darkMilk,
    required this.glassSurface,
    required this.active,
    required this.track,
    required this.thumb,
    required this.action,
  });

  final Color pageStart;
  final Color pageEnd;
  final Color milk;
  final Color darkMilk;
  final Color glassSurface;
  final Color active;
  final Color track;
  final Color thumb;
  final Color action;

  factory WenkuTonalColors.forScheme(
    ColorScheme scheme, {
    required bool eink,
    required bool oled,
    required bool highContrast,
  }) {
    final dark = scheme.brightness == Brightness.dark;
    if (eink) {
      return WenkuTonalColors(
        pageStart: Colors.white,
        pageEnd: Colors.white,
        milk: Colors.white,
        darkMilk: Colors.black,
        glassSurface: Colors.white,
        active: Colors.black,
        track: Colors.black,
        thumb: Colors.white,
        action: Colors.black,
      );
    }
    if (oled) {
      return WenkuTonalColors(
        pageStart: Colors.black,
        pageEnd: scheme.surfaceContainerLowest,
        milk: scheme.surfaceContainerLowest,
        darkMilk: scheme.onSurface,
        glassSurface: scheme.surface,
        active: scheme.onSurface,
        track: scheme.surfaceContainerHighest,
        thumb: scheme.onSurface,
        action: scheme.onSurface,
      );
    }
    return WenkuTonalColors(
      pageStart: dark ? ArchiveDesign.darkBackground : ArchiveDesign.surface,
      pageEnd: dark ? ArchiveDesign.darkSurface : ArchiveDesign.background,
      milk: ArchiveDesign.milk,
      darkMilk: ArchiveDesign.darkMilk,
      glassSurface: ArchiveDesign.darkSurface,
      active: Color.lerp(scheme.onSurface, scheme.surface, dark ? .46 : .48)!,
      track: Color.lerp(scheme.surface, scheme.onSurface, dark ? .16 : .10)!,
      thumb: ArchiveDesign.milk,
      action: scheme.onSurface,
    );
  }

  Color tint(Brightness brightness, double opacity) =>
      brightness == Brightness.dark
      ? Color.lerp(darkMilk, glassSurface, opacity.clamp(0, 1))!
      : milk;

  @override
  WenkuTonalColors copyWith({
    Color? pageStart,
    Color? pageEnd,
    Color? milk,
    Color? darkMilk,
    Color? glassSurface,
    Color? active,
    Color? track,
    Color? thumb,
    Color? action,
  }) => WenkuTonalColors(
    pageStart: pageStart ?? this.pageStart,
    pageEnd: pageEnd ?? this.pageEnd,
    milk: milk ?? this.milk,
    darkMilk: darkMilk ?? this.darkMilk,
    glassSurface: glassSurface ?? this.glassSurface,
    active: active ?? this.active,
    track: track ?? this.track,
    thumb: thumb ?? this.thumb,
    action: action ?? this.action,
  );

  @override
  WenkuTonalColors lerp(WenkuTonalColors? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return WenkuTonalColors(
      pageStart: c(pageStart, other.pageStart),
      pageEnd: c(pageEnd, other.pageEnd),
      milk: c(milk, other.milk),
      darkMilk: c(darkMilk, other.darkMilk),
      glassSurface: c(glassSurface, other.glassSurface),
      active: c(active, other.active),
      track: c(track, other.track),
      thumb: c(thumb, other.thumb),
      action: c(action, other.action),
    );
  }
}

abstract final class WenkuTheme {
  static const ink = Color(0xFF181818);
  static const accent = Color(0xFF202020);
  static const canvas = ArchiveDesign.background;
  static const hairline = Color(0xFFD8DBD5);

  static WenkuAppearance appearanceOf(BuildContext context) =>
      Theme.of(context).extension<WenkuAppearance>() ??
      const WenkuAppearance(eink: false, oled: false, highContrast: false);

  static bool isEinkOf(BuildContext context) => appearanceOf(context).eink;

  static ThemeData create(
    Brightness requestedBrightness, {
    bool eink = false,
    bool oled = false,
    bool highContrast = false,
  }) {
    if (eink) {
      return _withWenkuExtensions(
        AppTheme.createTheme(Brightness.light, einkMode: true),
        eink: true,
        oled: false,
        highContrast: highContrast,
      );
    }
    if (oled && requestedBrightness == Brightness.dark) {
      // Keep the archive's monochrome accents; only fqapp's OLED surfaces
      // (pure-black canvas, near-black plates, brighter outlines) replace
      // the upstream dark greys. fqapp's own OLED theme carries its orange
      // product accent, which upstream never shows.
      final archive = create(Brightness.dark, highContrast: highContrast);
      final pure = AppTheme.createTheme(
        Brightness.dark,
        oledMode: true,
      ).colorScheme;
      final scheme = archive.colorScheme.copyWith(
        surface: pure.surface,
        surfaceDim: Colors.black,
        surfaceContainerLowest: pure.surfaceContainerLowest,
        surfaceContainerLow: pure.surfaceContainerLow,
        surfaceContainer: pure.surfaceContainer,
        surfaceContainerHigh: pure.surfaceContainerHigh,
        surfaceContainerHighest: pure.surfaceContainerHighest,
        outline: pure.outline,
        outlineVariant: pure.outlineVariant,
      );
      return _withWenkuExtensions(
        archive.copyWith(
          colorScheme: scheme,
          scaffoldBackgroundColor: Colors.black,
          dividerColor: pure.outlineVariant,
        ),
        eink: false,
        oled: true,
        highContrast: highContrast,
      );
    }

    // Extracted from the upstream novelTheme original palette. Do not replace
    // this with hand-picked fqapp colors: the archive surfaces are intentional.
    final dark = requestedBrightness == Brightness.dark;
    final baseScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: requestedBrightness,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      primary: dark ? Colors.white : ink,
      onPrimary: dark ? ink : Colors.white,
      surface: dark ? ArchiveDesign.darkSurface : ArchiveDesign.surface,
      onSurface: dark ? ArchiveDesign.darkInk : ink,
      onSurfaceVariant: dark
          ? ArchiveDesign.darkMuted
          : const Color(0xFF646B62),
    );
    final scheme = dark
        ? baseScheme.copyWith(
            surfaceDim: ArchiveDesign.darkBackground,
            surfaceBright: ArchiveDesign.darkRaisedHigh,
            surfaceContainerLowest: ArchiveDesign.darkBackground,
            surfaceContainerLow: ArchiveDesign.darkSurface,
            surfaceContainer: ArchiveDesign.darkRaised,
            surfaceContainerHigh: const Color(0xFF333333),
            surfaceContainerHighest: ArchiveDesign.darkRaisedHigh,
            outline: const Color(0xFF7A7A7A),
            outlineVariant: ArchiveDesign.darkOutline,
            surfaceTint: Colors.transparent,
          )
        : baseScheme;
    final theme = ThemeData(
      useMaterial3: true,
      brightness: requestedBrightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? ArchiveDesign.darkBackground : canvas,
      cupertinoOverrideTheme: CupertinoThemeData(
        brightness: requestedBrightness,
        primaryColor: scheme.primary,
        primaryContrastingColor: scheme.onPrimary,
        scaffoldBackgroundColor: scheme.surface,
      ),
      splashFactory: InkRipple.splashFactory,
      textTheme: ThemeData(brightness: requestedBrightness).textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      dividerColor: dark ? ArchiveDesign.darkOutline : hairline,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
          borderSide: BorderSide(
            color: dark ? ArchiveDesign.darkOutline : hairline,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(
          color: scheme.onInverseSurface,
          height: 1.5,
        ),
        actionTextColor: scheme.onInverseSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
        ),
      ),
    );
    return _withWenkuExtensions(
      theme,
      eink: false,
      oled: false,
      highContrast: highContrast,
    );
  }

  static ThemeData _withWenkuExtensions(
    ThemeData theme, {
    required bool eink,
    required bool oled,
    required bool highContrast,
  }) => theme.copyWith(
    extensions: [
      WenkuAppearance(eink: eink, oled: oled, highContrast: highContrast),
      WenkuTonalColors.forScheme(
        theme.colorScheme,
        eink: eink,
        oled: oled,
        highContrast: highContrast,
      ),
    ],
  );
}

/// Applies the ported Wenku8 monochrome theme and its finite entrance clock.
///
/// A host may wrap several pages in one scope. [WenkuPage] detects that scope
/// and will not install a second theme or animation controller.
class WenkuScope extends StatefulWidget {
  const WenkuScope({
    super.key,
    required this.child,
    this.reduceMotion,
    this.highContrast,
    this.entrance = true,
    this.performance = const PerformancePreferences(),
  });

  final Widget child;
  final bool? reduceMotion;
  final bool? highContrast;
  final bool entrance;
  final PerformancePreferences performance;

  static bool isActive(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WenkuScopeMarker>() != null;

  @override
  State<WenkuScope> createState() => _WenkuScopeState();
}

class _WenkuScopeState extends State<WenkuScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: WenkuMotion.enter,
      value: widget.entrance ? 0 : 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(WenkuScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entrance != widget.entrance ||
        oldWidget.reduceMotion != widget.reduceMotion ||
        oldWidget.performance != widget.performance) {
      _syncMotion();
    }
  }

  void _syncMotion() {
    final media = MediaQuery.maybeOf(context);
    final eink = einkModeNotifier.value;
    final reduce =
        widget.reduceMotion ??
        ((media?.disableAnimations ?? false) ||
            (widget.performance.enabled && !widget.performance.motion));
    if (!widget.entrance || eink || reduce) {
      _entrance
        ..stop()
        ..value = 1;
      return;
    }
    if (_started || _entrance.value > 0) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _entrance.value == 0) _entrance.forward();
    });
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media =
        MediaQuery.maybeOf(context) ??
        const MediaQueryData(size: Size(800, 600));
    final outer = Theme.of(context);
    final eink = einkModeNotifier.value;
    final oled = !eink && oledActive(systemBrightness: outer.brightness);
    final highContrast = widget.highContrast ?? media.highContrast;
    final reduceMotion = widget.reduceMotion ?? media.disableAnimations;
    final disableAnimations =
        reduceMotion ||
        eink ||
        (widget.performance.enabled && !widget.performance.motion);
    final effectiveMedia = media.copyWith(
      disableAnimations: disableAnimations,
      highContrast: highContrast,
    );
    final theme = WenkuTheme.create(
      outer.brightness,
      eink: eink,
      oled: oled,
      highContrast: highContrast,
    );
    return MediaQuery(
      data: effectiveMedia,
      child: Theme(
        data: theme,
        child: PerformanceScope(
          preferences: widget.performance,
          explicitReduceMotion: disableAnimations,
          child: ArchiveMotionScope(
            animation: _entrance,
            enabled: !disableAnimations,
            child: _WenkuScopeMarker(
              eink: eink,
              oled: oled,
              highContrast: highContrast,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class _WenkuScopeMarker extends InheritedWidget {
  const _WenkuScopeMarker({
    required this.eink,
    required this.oled,
    required this.highContrast,
    required super.child,
  });

  final bool eink;
  final bool oled;
  final bool highContrast;

  @override
  bool updateShouldNotify(_WenkuScopeMarker oldWidget) =>
      eink != oldWidget.eink ||
      oled != oldWidget.oled ||
      highContrast != oldWidget.highContrast;
}
