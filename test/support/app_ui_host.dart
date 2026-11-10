import 'package:flutter/material.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';

/// Mounts [home] with the same presentation wiring as `main.dart`: one
/// [AppUiScope] inside `MaterialApp.builder`, above the root Navigator (and
/// therefore above nested Navigators and Overlay entries), plus the animated
/// Theme fed by the same [AppThemeStyleStore].
///
/// [followTheme] mirrors production (`true`). Pass `false` when a test keeps
/// the theme fixed to prove that the scope alone reaches display dependents,
/// or to model a theme whose animated tokens disagree with the live style.
///
/// This host intentionally does not inject local data or providers; page tests
/// that need them keep their own fixtures and only wrap the page in
/// [AppUiScope].
class AppUiHost extends StatelessWidget {
  const AppUiHost({
    super.key,
    required this.store,
    required this.home,
    this.navigatorKey,
    this.followTheme = true,
    this.themeAnimationDuration = const Duration(milliseconds: 200),
  });

  final AppThemeStyleStore store;
  final Widget home;
  final GlobalKey<NavigatorState>? navigatorKey;
  final bool followTheme;
  final Duration themeAnimationDuration;

  Widget _app(AppThemeStyle style) => MaterialApp(
    navigatorKey: navigatorKey,
    theme: AppTheme.createTheme(Brightness.light, style: style),
    themeAnimationDuration: themeAnimationDuration,
    builder: (context, child) =>
        AppUiScope(store: store, child: child ?? const SizedBox.shrink()),
    home: home,
  );

  @override
  Widget build(BuildContext context) {
    if (!followTheme) return _app(AppThemeStyle.archive);
    return ValueListenableBuilder<AppThemeStyle>(
      valueListenable: store,
      builder: (context, style, _) => _app(style),
    );
  }
}

/// Clears [AppUiScope] diagnostics so a test can assert that a tree never used
/// the missing-scope fallback.
void resetAppUiTestDiagnostics() => AppUiScope.debugFallbackReads = 0;
