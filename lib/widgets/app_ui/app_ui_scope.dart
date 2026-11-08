import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../services/app_style_tokens.dart';
import '../../services/app_theme_style.dart';

/// Discrete presentation policy for the selected [AppThemeStyle].
///
/// A layout branch must decide once per selection, never from the in-between
/// value `AppStyleTokens.lerp` produces while `AnimatedTheme` animates. The
/// tokens here are the target style's own constants, so classic/archive
/// branches cannot flip back and forth mid-transition.
@immutable
class AppUiPresentation {
  const AppUiPresentation._(this.style, this.tokens);

  static AppUiPresentation forStyle(AppThemeStyle style) => switch (style) {
    AppThemeStyle.classic => const AppUiPresentation._(
      AppThemeStyle.classic,
      AppStyleTokens.classic(),
    ),
    AppThemeStyle.archive => const AppUiPresentation._(
      AppThemeStyle.archive,
      AppStyleTokens.archive(),
    ),
  };

  final AppThemeStyle style;

  /// Target-style constants, not the animated `ThemeExtension`.
  final AppStyleTokens tokens;

  bool get isClassic => style == AppThemeStyle.classic;

  bool get showDecorativeCodes => tokens.showDecorativeCodes;
}

/// One live, app-wide presentation scope for the current [AppThemeStyle].
///
/// `main.dart` installs it inside `MaterialApp.builder`, above the root
/// Navigator (and therefore above nested Navigators and every Overlay entry).
/// Displays read the discrete style from here; [AppThemeStyleStore] remains
/// the only state owner and the only thing that writes the preference.
///
/// The scope is a plain inherited scope, not an `InheritedTheme`: popup routes
/// that capture themes for reader paper still find it through their ancestors,
/// so an already-open sheet does not freeze the style it opened with.
///
/// Reading is harmless when the scope is absent (single-page widget tests and
/// compatibility call sites): it falls back to the surrounding
/// [AppStyleTokens]. Production entry points are expected to provide the
/// scope; [debugFallbackReads] makes a missing one measurable in tests.
class AppUiScope extends InheritedNotifier<AppThemeStyleStore> {
  const AppUiScope({
    super.key,
    required AppThemeStyleStore store,
    required super.child,
  }) : super(notifier: store);

  /// Number of fallback reads in debug builds. Reset it before exercising a
  /// production entry point to prove that tree never relies on the fallback.
  @visibleForTesting
  static int debugFallbackReads = 0;

  /// Subscribes to the live style and returns the scope, or null if absent.
  static AppUiScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppUiScope>();

  /// Whether an [AppUiScope] is above [context]. Does not subscribe.
  static bool isAvailable(BuildContext context) =>
      context.getElementForInheritedWidgetOfExactType<AppUiScope>() != null;

  /// The live discrete style. Never the animated token value.
  ///
  /// Missing-scope fallback: the surrounding theme's [AppStyleTokens], which
  /// keeps existing theme-only widget tests and unmigrated call sites on their
  /// previous behaviour instead of throwing.
  static AppThemeStyle of(BuildContext context) {
    final scope = maybeOf(context);
    if (scope != null) return scope.notifier!.value;
    return _fallbackStyle(context);
  }

  /// Discrete target-style constants for layout branches.
  static AppUiPresentation presentationOf(BuildContext context) =>
      AppUiPresentation.forStyle(of(context));

  static bool isClassic(BuildContext context) =>
      of(context) == AppThemeStyle.classic;

  static AppThemeStyle _fallbackStyle(BuildContext context) {
    if (kDebugMode) debugFallbackReads++;
    return AppStyleTokens.of(context).style;
  }
}
