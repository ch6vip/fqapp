import 'package:flutter/material.dart';

/// Persisted theme-mode preference key: 'theme_mode' = 'light'|'dark'|'system'.
const themeModeKey = 'theme_mode';

/// Brand seed color for the whole app (also used by the player slider and
/// the detail page's accent text).
const appSeedColor = Color(0xFFEF5038);

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

/// Unified design system and theme factory for fqapp.
class AppTheme {
  static const Color accent = Color(0xFFEF5038);
  static const Color accentStrong = Color(0xFFC73D29);
  static const Color accentDark = Color(0xFFF05E47);

  static ThemeData createTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final primary = isDark ? accentDark : accent;
    final canvas = isDark ? const Color(0xFF151517) : const Color(0xFFFCFAF7);
    final surface = isDark ? const Color(0xFF242427) : Colors.white;
    final surfaceContainerLow =
        isDark ? const Color(0xFF1C1C1F) : const Color(0xFFF7F5F0);
    final surfaceContainer =
        isDark ? const Color(0xFF242428) : const Color(0xFFF2EFE9);
    final surfaceContainerHigh =
        isDark ? const Color(0xFF2C2C32) : const Color(0xFFEBE7DF);
    final ink = isDark ? const Color(0xFFF5F1EB) : const Color(0xFF262522);
    final muted = isDark ? const Color(0xFFA7A39E) : const Color(0xFF706C66);
    final line = isDark ? const Color(0xFF333336) : const Color(0xFFE8E4DE);

    final scheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer:
          isDark ? const Color(0xFF381C17) : const Color(0xFFFFECE8),
      onPrimaryContainer:
          isDark ? const Color(0xFFFFDAD4) : const Color(0xFF410002),
      secondary: isDark ? const Color(0xFFE5806B) : const Color(0xFFD3513B),
      onSecondary: Colors.white,
      secondaryContainer:
          isDark ? const Color(0xFF33201C) : const Color(0xFFFFECE5),
      onSecondaryContainer:
          isDark ? const Color(0xFFFFDAD2) : const Color(0xFF3C0E07),
      tertiary: isDark ? const Color(0xFF7DB3EC) : const Color(0xFF4A90D9),
      onTertiary: Colors.white,
      surface: surface,
      onSurface: ink,
      surfaceContainerLowest: isDark ? const Color(0xFF0F0F11) : Colors.white,
      surfaceContainerLow: surfaceContainerLow,
      surfaceContainer: surfaceContainer,
      surfaceContainerHigh: surfaceContainerHigh,
      surfaceContainerHighest:
          isDark ? const Color(0xFF34343A) : const Color(0xFFE4DFD6),
      onSurfaceVariant: muted,
      outline: isDark ? const Color(0xFF7A7670) : const Color(0xFF9E9A92),
      outlineVariant: line,
      error: isDark ? const Color(0xFFFFB4AB) : const Color(0xFFBA1A1A),
      onError: isDark ? const Color(0xFF690005) : Colors.white,
      errorContainer:
          isDark ? const Color(0xFF93000A) : const Color(0xFFFFDAD6),
      onErrorContainer:
          isDark ? const Color(0xFFFFDAD6) : const Color(0xFF410002),
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ink,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(size: 22, color: ink),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: line, width: 0.6),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: line, width: 0.6),
        ),
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
        contentTextStyle: TextStyle(
          fontSize: 14,
          color: muted,
          height: 1.4,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        dragHandleColor: line,
        dragHandleSize: const Size(36, 4),
      ),
      dividerTheme: DividerThemeData(
        color: line,
        thickness: 0.6,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        dense: false,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: ink,
        ),
        subtitleTextStyle: TextStyle(
          fontSize: 12.5,
          color: muted,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor:
            isDark ? const Color(0xFF2C2C30) : const Color(0xFF2C2825),
        contentTextStyle: const TextStyle(fontSize: 13, color: Colors.white),
      ),
    );
  }
}
