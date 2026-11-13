import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';

/// Locks the #15/#9 contract: e-ink surfaces are pure white #FFFFFF with
/// pure black #000000 text, never a tonal / seed-derived grey.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('reader e-ink preset is pure black on pure white', () {
    const preset = ReaderThemePreset.eink;
    expect(preset.backgroundColor, Colors.white);
    expect(preset.textColor, Colors.black);
    expect(preset.accentColor, Colors.black);
    expect(preset.selectionAccentColor, Colors.black);
    expect(preset.mutedTextColor, Colors.black);
    expect(preset.panelColor, Colors.white);
    expect(preset.fieldColor, Colors.white);
    expect(preset.borderColor, Colors.black);
  });

  test('reader e-ink theme does not use a tonal seed palette', () {
    final base = ThemeData.light();
    final theme = ReaderThemePreset.eink.theme(base);
    expect(theme.colorScheme.surface, Colors.white);
    expect(theme.colorScheme.onSurface, Colors.black);
    expect(theme.colorScheme.primary, Colors.black);
    expect(theme.scaffoldBackgroundColor, Colors.white);
  });

  test('global e-ink theme is pure black on pure white without ripple', () {
    final theme = AppTheme.createTheme(Brightness.dark, einkMode: true);
    // Dark mode is intentionally not honoured for e-ink: inverted pages
    // ghost badly on e-ink screens.
    expect(theme.brightness, Brightness.light);
    expect(theme.colorScheme.surface, Colors.white);
    expect(theme.colorScheme.onSurface, Colors.black);
    expect(theme.colorScheme.primary, Colors.black);
    expect(theme.scaffoldBackgroundColor, Colors.white);
    expect(theme.splashFactory, NoSplash.splashFactory);
  });

  test('non-eink themes keep their existing palettes', () {
    final light = AppTheme.createTheme(Brightness.light);
    expect(light.colorScheme.primary, AppTheme.accent);
    expect(ReaderThemePreset.light.backgroundColor, const Color(0xFFFAF9F6));
    expect(ReaderThemePreset.light.textColor, const Color(0xFF292724));
  });

  test('e-ink reader preset survives a save / load round-trip', () async {
    const expected = ReaderPreferences(themePreset: ReaderThemePreset.eink);
    await expected.save();
    final restored = await ReaderPreferences.load();
    expect(restored.themePreset, ReaderThemePreset.eink);
  });
}
