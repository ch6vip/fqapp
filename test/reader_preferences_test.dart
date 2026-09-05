import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/reader_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('reader preferences persist all appearance values', () async {
    const expected = ReaderPreferences(
      fontSize: 23,
      fontWeight: 600,
      lineHeight: 1.65,
      paragraphSpacing: 18,
      horizontalPadding: 28,
      themePreset: ReaderThemePreset.eyeCare,
    );

    await expected.save();
    final restored = await ReaderPreferences.load();

    expect(restored.fontSize, 23);
    expect(restored.fontWeight, 600);
    expect(restored.lineHeight, 1.65);
    expect(restored.paragraphSpacing, 18);
    expect(restored.horizontalPadding, 28);
    expect(restored.themePreset, ReaderThemePreset.eyeCare);
  });

  test('reader preferences normalize invalid stored values', () async {
    SharedPreferences.setMockInitialValues({
      'reader_font_size': 99,
      'reader_font_weight': 455,
      'reader_line_height': 0.5,
      'reader_paragraph_spacing': -4,
      'reader_horizontal_padding': 100,
      'reader_theme_preset': 'missing',
    });

    final restored = await ReaderPreferences.load();

    expect(restored.fontSize, 32);
    expect(restored.fontWeight, 500);
    expect(restored.lineHeight, 1.2);
    expect(restored.paragraphSpacing, 0);
    expect(restored.horizontalPadding, 48);
    expect(restored.themePreset, ReaderThemePreset.light);
  });
}
