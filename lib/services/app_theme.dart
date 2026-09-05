import 'package:flutter/material.dart';

/// Persisted theme-mode preference key: 'theme_mode' = 'light'|'dark'|'system'.
const themeModeKey = 'theme_mode';

/// Brand seed color for the whole app (also used by the player slider and
/// the detail page's accent text).
const appSeedColor = Color(0xFFE8532D);

/// Global theme-mode notifier; the settings page writes it, MaterialApp
/// rebuilds with the new mode.
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.system,
);

ThemeMode themeModeFromName(String? name) {
  switch (name) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}
