import 'package:flutter/material.dart';

import '../../services/app_theme.dart';
import '../wenku/src/performance_preferences.dart';

/// Merges the user's 立体书架 preference with the e-ink and reduced-motion
/// signals for the library page.
///
/// The library page is mounted outside `WenkuScope`
/// (`F/lib/main.dart`), so `PerformanceScope.of(context)` alone would always
/// report the default `shelf3d = true`. This scope is placed inside the page
/// body, around both the skeleton and the carousel, so the loading bank and
/// the arriving bank share one switch.
class ShelfPerformanceScope extends StatelessWidget {
  const ShelfPerformanceScope({
    super.key,
    required this.shelf3d,
    this.reduceMotion,
    required this.child,
  });

  /// User intent. E-ink mode forces a flat shelf even when this is true.
  final bool shelf3d;

  /// Explicit reduced-motion signal. Null falls back to
  /// `MediaQuery.disableAnimations`.
  final bool? reduceMotion;
  final Widget child;

  /// Outer effects other than `shelf3d` are preserved verbatim; only
  /// `shelf3d` is added or removed from the merged preset.
  ///
  /// The result always has `enabled = true`: a disabled preset means "every
  /// effect allowed", which cannot express "everything except 3D". Callers
  /// must therefore read individual effects (or [PerformancePreferences.allows])
  /// and never use `.enabled` to decide whether the lightweight preset is on.
  static PerformancePreferences preferencesFor(
    PerformancePreferences outer, {
    required bool shelf3d,
  }) {
    // A disabled preset means "all effects allowed". Materialize that as an
    // explicit effect set so `shelf3d=false` still means something, while every
    // other effect keeps its effective value.
    final preserved = outer.enabled
        ? outer.effects
        : PerformanceEffect.values.toSet();
    final effects = <PerformanceEffect>{
      ...preserved.where((effect) => effect != PerformanceEffect.shelf3d),
      if (shelf3d) PerformanceEffect.shelf3d,
    };
    return PerformancePreferences(
      enabled: true,
      effects: Set.unmodifiable(effects),
    );
  }

  @override
  Widget build(BuildContext context) {
    final eink = einkModeNotifier.value;
    final effectiveShelf3d = shelf3d && !eink;
    final reduce = reduceMotion ?? MediaQuery.disableAnimationsOf(context);
    final preferences = preferencesFor(
      PerformanceScope.of(context),
      shelf3d: effectiveShelf3d,
    );
    return PerformanceScope(
      preferences: preferences,
      explicitReduceMotion: reduce,
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: reduce || eink),
        child: child,
      ),
    );
  }
}
