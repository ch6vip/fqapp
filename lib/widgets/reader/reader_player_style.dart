import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';

/// Official 7.0.9.32: un4.j.e (b7h/b7j/b7k/b7l),
/// ReaderCommonColor.getGlobalButtonTextColor / getGlobalText70Color.
extension ReaderPlayerColors on ReaderThemePreset {
  Color get playerBackground => switch (this) {
    ReaderThemePreset.light => const Color(0xFF6B6B6B),
    ReaderThemePreset.eyeCare => const Color(0xFF6A7065),
    ReaderThemePreset.parchment => const Color(0xFF7E6E52),
    ReaderThemePreset.dark => const Color(0xFF333333),
    ReaderThemePreset.eink => Colors.black,
  };

  Color get playerText => switch (this) {
    ReaderThemePreset.eyeCare => const Color(0xFFEDFAE9),
    ReaderThemePreset.parchment => const Color(0xFFFFF1E0),
    ReaderThemePreset.dark => const Color(0x99FFFFFF),
    _ => Colors.white,
  };

  Color get playerWeakText => switch (this) {
    ReaderThemePreset.light => const Color(0xB2303030),
    ReaderThemePreset.eyeCare => const Color(0xB2272A26),
    ReaderThemePreset.parchment => const Color(0xB2462E0B),
    ReaderThemePreset.dark => const Color(0xCC8A8A8A),
    ReaderThemePreset.eink => Colors.black,
  };
}
