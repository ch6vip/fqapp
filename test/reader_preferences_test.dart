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
      letterSpacing: 0.8,
      verticalPadding: 30,
      titleSize: 28,
      titleAlignment: ReaderTitleAlignment.center,
      showReadingInfo: false,
      followSystemBrightness: false,
      brightness: 0.3,
      fontPath: '/private/reader-fonts/test.font',
      fontName: '测试宋体.ttf',
      pageMode: ReaderPageMode.scroll,
    );

    await expected.save();
    final restored = await ReaderPreferences.load();

    expect(restored.fontSize, 23);
    expect(restored.fontWeight, 600);
    expect(restored.lineHeight, 1.65);
    expect(restored.paragraphSpacing, 18);
    expect(restored.horizontalPadding, 28);
    expect(restored.themePreset, ReaderThemePreset.eyeCare);
    expect(restored.letterSpacing, 0.8);
    expect(restored.verticalPadding, 30);
    expect(restored.titleSize, 28);
    expect(restored.titleAlignment, ReaderTitleAlignment.center);
    expect(restored.showReadingInfo, isFalse);
    expect(restored.followSystemBrightness, isFalse);
    expect(restored.brightness, 0.3);
    expect(restored.fontPath, '/private/reader-fonts/test.font');
    expect(restored.fontName, '测试宋体.ttf');
    expect(restored.pageMode, ReaderPageMode.scroll);
  });

  test('reader preferences normalize invalid stored values', () async {
    SharedPreferences.setMockInitialValues({
      'reader_font_size': 99,
      'reader_font_weight': 455,
      'reader_line_height': 0.5,
      'reader_paragraph_spacing': -4,
      'reader_horizontal_padding': 100,
      'reader_theme_preset': 'missing',
      'reader_letter_spacing': 8,
      'reader_vertical_padding': -10,
      'reader_title_size': 100,
      'reader_title_alignment': 'unknown',
      'reader_show_reading_info': 'no',
      'reader_follow_system_brightness': 3,
      'reader_brightness': 0,
      'reader_page_mode': 'unknown',
    });

    final restored = await ReaderPreferences.load();

    expect(restored.fontSize, 32);
    expect(restored.fontWeight, 500);
    expect(restored.lineHeight, 1.2);
    expect(restored.paragraphSpacing, 0);
    expect(restored.horizontalPadding, 48);
    expect(restored.themePreset, ReaderThemePreset.light);
    expect(restored.letterSpacing, 3);
    expect(restored.verticalPadding, 0);
    expect(restored.titleSize, 40);
    expect(restored.titleAlignment, ReaderTitleAlignment.start);
    expect(restored.showReadingInfo, isTrue);
    expect(restored.followSystemBrightness, isTrue);
    expect(restored.brightness, 0.02);
    expect(restored.pageMode, ReaderPageMode.paged);
  });

  test(
    'wrong types and non-finite values fall back to safe defaults',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader_font_size': double.nan,
        'reader_font_weight': double.infinity,
        'reader_line_height': 'large',
        'reader_paragraph_spacing': double.negativeInfinity,
        'reader_horizontal_padding': double.nan,
        'reader_theme_preset': 42,
      });
      final restored = await ReaderPreferences.load();
      expect(restored.fontSize, 18);
      expect(restored.fontWeight, 400);
      expect(restored.lineHeight, 1.8);
      expect(restored.paragraphSpacing, 12);
      expect(restored.horizontalPadding, 20);
      expect(restored.themePreset, ReaderThemePreset.light);
    },
  );

  test('normalization never passes non-finite dimensions to the reader', () {
    final value = const ReaderPreferences(
      fontSize: double.nan,
      lineHeight: double.infinity,
      paragraphSpacing: double.negativeInfinity,
      horizontalPadding: double.nan,
    ).normalized();
    expect(value.fontSize, 18);
    expect(value.lineHeight, 1.8);
    expect(value.paragraphSpacing, 12);
    expect(value.horizontalPadding, 20);
  });

  test(
    'legacy preferences preserve their title size and use system brightness',
    () async {
      SharedPreferences.setMockInitialValues({'reader_font_size': 24});
      final restored = await ReaderPreferences.load();
      expect(restored.titleSize, 26);
      expect(restored.followSystemBrightness, isTrue);
      expect(restored.fontPath, isEmpty);
    },
  );

  test(
    'overlapping saves leave one complete latest preference snapshot',
    () async {
      final first = const ReaderPreferences(
        fontSize: 16,
        brightness: 0.2,
      ).save();
      final last = const ReaderPreferences(
        fontSize: 25,
        brightness: 0.7,
        titleAlignment: ReaderTitleAlignment.center,
        followSystemBrightness: false,
      ).save();
      final restored = await ReaderPreferences.load();
      await Future.wait([first, last]);
      expect(restored.fontSize, 25);
      expect(restored.brightness, 0.7);
      expect(restored.followSystemBrightness, isFalse);
      expect(restored.titleAlignment, ReaderTitleAlignment.center);
    },
  );
}
