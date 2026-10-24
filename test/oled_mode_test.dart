import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/detail/detail_hero.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';

void main() {
  test('oled theme uses a pure black canvas but near-black surfaces', () {
    final theme = AppTheme.createTheme(Brightness.dark, oledMode: true);

    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, Colors.black);
    expect(theme.canvasColor, Colors.black);
    expect(theme.colorScheme.surfaceContainerLowest, Colors.black);
    // Surfaces deliberately stay off pure black: black-on-black would erase
    // cards, sheets and pure-black posters.
    expect(theme.colorScheme.surface, const Color(0xFF0C0C0E));
    expect(theme.colorScheme.surface, isNot(Colors.black));
    expect(theme.colorScheme.onSurface, const Color(0xFFF5F1EB));
    expect(theme.colorScheme.outlineVariant, const Color(0xFF3F3F47));

    final shape = theme.cardTheme.shape! as RoundedRectangleBorder;
    expect(shape.side.color, const Color(0xFF2E2E34));
  });

  test('oled mode is ignored by the light theme', () {
    final light = AppTheme.createTheme(Brightness.light, oledMode: true);
    expect(light.brightness, Brightness.light);
    expect(light.scaffoldBackgroundColor, const Color(0xFFFCFAF7));
    expect(light.colorScheme.surface, Colors.white);
  });

  test('弹层的发丝线只给深色 / OLED，浅色与墨水屏不加', () {
    // 这圈线是为了把近黑浮层从纯黑画布上分出来。浅色弹层与奶白画布本来
    // 就靠 barrier 区分；墨水屏的 line 是纯黑，下发后会在弹层四周描黑边。
    const light = HomePalette(false);
    const dark = HomePalette(true);
    const eink = HomePalette(false, eink: true);

    expect(homeSheetShape(light).side, BorderSide.none);
    expect(homeSheetShape(eink).side, BorderSide.none);
    expect(homeSheetShape(dark).side.width, 0.8);
    expect(homeSheetShape(dark).side.color, dark.line.withValues(alpha: 0.8));
    // 圆角与深度无关，去掉描边不能把它一起改掉。
    expect(
      homeSheetShape(light, top: 16).borderRadius,
      const BorderRadius.vertical(top: Radius.circular(16)),
    );
  });

  test('e-ink wins when both modes are enabled', () {
    final theme = AppTheme.createTheme(
      Brightness.dark,
      einkMode: true,
      oledMode: true,
    );
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, Colors.white);
  });

  test('dark theme without oled keeps the existing palette', () {
    final dark = AppTheme.createTheme(Brightness.dark);
    expect(dark.scaffoldBackgroundColor, const Color(0xFF151517));
    expect(dark.colorScheme.surface, const Color(0xFF242427));
  });

  test('home palette follows oled mode', () {
    const palette = HomePalette(true, oled: true);
    expect(palette.canvas, Colors.black);
    expect(palette.surface, const Color(0xFF0C0C0E));
    expect(palette.soft, const Color(0xFF141417));
    expect(palette.line, const Color(0xFF2E2E34));
  });

  test('oled preference key is stable', () {
    expect(oledModeKey, 'oled_mode');
    expect(oledModeNotifier.value, isFalse);
  });

  group('oled only applies to the dark appearance', () {
    tearDown(() {
      oledModeNotifier.value = false;
      einkModeNotifier.value = false;
      themeModeNotifier.value = ThemeMode.system;
    });

    test('light appearance ignores the saved oled preference', () {
      oledModeNotifier.value = true;
      themeModeNotifier.value = ThemeMode.light;
      expect(isDarkAppearance(), isFalse);
      expect(oledActive(), isFalse);
    });

    test('dark appearance activates oled', () {
      oledModeNotifier.value = true;
      themeModeNotifier.value = ThemeMode.dark;
      expect(isDarkAppearance(), isTrue);
      expect(oledActive(), isTrue);
    });

    test('follow-system tracks the system brightness', () {
      oledModeNotifier.value = true;
      themeModeNotifier.value = ThemeMode.system;
      expect(oledActive(systemBrightness: Brightness.dark), isTrue);
      expect(oledActive(systemBrightness: Brightness.light), isFalse);
    });

    test('e-ink is a light appearance, so oled never applies there', () {
      oledModeNotifier.value = true;
      themeModeNotifier.value = ThemeMode.dark;
      einkModeNotifier.value = true;
      expect(isDarkAppearance(), isFalse);
      expect(oledActive(), isFalse);
    });
  });

  group('settings appearance entry', () {
    tearDown(() {
      oledModeNotifier.value = false;
      einkModeNotifier.value = false;
      themeModeNotifier.value = ThemeMode.system;
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('oled row and e-ink option share the theme-mode entry', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      // 设置页在 Windows 宿主上会走桌面布局，这里按手机布局渲染。
      // 框架在测试体结束后立即校验调试变量，必须在体内恢复。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        themeModeNotifier.value = ThemeMode.light;
        // 和 main.dart 一样监听三个 notifier：换主题时不能重建 Navigator，
        // 否则分类页被重新推入，测不到「原地刷新」这个行为。
        await tester.pumpWidget(
          ListenableBuilder(
            listenable: Listenable.merge([
              themeModeNotifier,
              einkModeNotifier,
              oledModeNotifier,
            ]),
            builder: (context, _) {
              final eink = einkModeNotifier.value;
              final oled = oledModeNotifier.value;
              return MaterialApp(
                theme: AppTheme.createTheme(
                  Brightness.light,
                  einkMode: eink,
                  oledMode: oled,
                ),
                darkTheme: AppTheme.createTheme(
                  Brightness.dark,
                  oledMode: oled,
                ),
                // 墨水屏恒为浅色主题，与 app 一致。
                themeMode: eink ? ThemeMode.light : themeModeNotifier.value,
                home: const SettingsPage(),
              );
            },
          ),
        );
        await tester.pump();
        // 设置首页只列分类，外观项在分类页里。
        await tester.tap(find.text('外观'));
        await tester.pumpAndSettle();

        expect(find.text('主题模式'), findsOneWidget);
        expect(find.text('浅色'), findsOneWidget);
        expect(find.text('OLED 纯黑'), findsNothing);

        // 切到深色：OLED 行必须当场出现，不需要退出重进。
        await tester.tap(find.text('主题模式'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('深色'));
        await tester.pumpAndSettle();
        expect(find.text('深色'), findsOneWidget);
        expect(find.text('OLED 纯黑'), findsOneWidget);

        // 墨水屏同样是第四项；选中后 OLED 行当场消失（墨水屏恒为浅色）。
        await tester.tap(find.text('主题模式'));
        await tester.pumpAndSettle();
        expect(find.text('墨水屏'), findsOneWidget);
        expect(find.text('跟随系统'), findsOneWidget);
        await tester.tap(find.text('墨水屏'));
        await tester.pumpAndSettle();
        expect(find.text('墨水屏'), findsOneWidget);
        expect(find.text('OLED 纯黑'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('reader follows oled mode', () {
    setUp(() => themeModeNotifier.value = ThemeMode.dark);

    tearDown(() {
      oledModeNotifier.value = false;
      themeModeNotifier.value = ThemeMode.system;
    });

    test('reader dark preset becomes pure black with near-black panels', () {
      oledModeNotifier.value = true;
      const preset = ReaderThemePreset.dark;

      expect(preset.isOled, isTrue);
      expect(preset.backgroundColor, Colors.black);
      // 浮层仍比底色亮一档，否则目录 / 排版面板在纯黑上找不到边界。
      expect(preset.panelColor, const Color(0xFF0C0C0E));
      expect(preset.fieldColor, const Color(0xFF141417));
      expect(preset.borderColor, const Color(0xFF2E2E34));
      expect(preset.mutedTextColor, const Color(0xFF9E9A94));
      // 排版面板底色：纯黑页面上再铺纯黑会让面板边界消失。
      expect(preset.sheetColor, const Color(0xFF0C0C0E));

      final theme = preset.theme(ThemeData.light());
      expect(theme.scaffoldBackgroundColor, Colors.black);
      expect(theme.colorScheme.surface, const Color(0xFF0C0C0E));
      expect(
        theme.colorScheme.surfaceContainerHighest,
        const Color(0xFF1F1F23),
      );
      expect(theme.bottomSheetTheme.backgroundColor, const Color(0xFF0C0C0E));
    });

    test('reader light presets ignore oled mode', () {
      oledModeNotifier.value = true;
      expect(ReaderThemePreset.light.isOled, isFalse);
      expect(ReaderThemePreset.light.backgroundColor, const Color(0xFFFAF9F6));
      expect(
        ReaderThemePreset.parchment.backgroundColor,
        const Color(0xFFF3E4C2),
      );
      expect(ReaderThemePreset.eink.backgroundColor, Colors.white);
    });

    test('reader dark preset keeps #171717 without oled', () {
      expect(ReaderThemePreset.dark.isOled, isFalse);
      expect(ReaderThemePreset.dark.backgroundColor, const Color(0xFF171717));
      // 没有 OLED 时排版面板仍与页面同色（官方 parity）。
      expect(ReaderThemePreset.dark.sheetColor, const Color(0xFF171717));
      expect(ReaderThemePreset.dark.panelColor, isNot(const Color(0xFF0C0C0E)));
    });

    test('reader dark preset ignores oled when the app is light', () {
      oledModeNotifier.value = true;
      themeModeNotifier.value = ThemeMode.light;
      expect(ReaderThemePreset.dark.isOled, isFalse);
      expect(ReaderThemePreset.dark.backgroundColor, const Color(0xFF171717));
    });

    test('reader theme cache separates oled from the plain dark theme', () {
      final base = ThemeData.light();
      final plain = ReaderThemePreset.dark.theme(base);
      oledModeNotifier.value = true;
      final oled = ReaderThemePreset.dark.theme(base);

      expect(identical(plain, oled), isFalse);
      expect(plain.scaffoldBackgroundColor, const Color(0xFF171717));
      expect(oled.scaffoldBackgroundColor, Colors.black);
    });
  });

  group('the detail masthead wash follows the appearance', () {
    tearDown(() {
      oledModeNotifier.value = false;
      einkModeNotifier.value = false;
      themeModeNotifier.value = ThemeMode.system;
    });

    Future<void> pumpWash(WidgetTester tester, ThemeData theme) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: DetailMastheadWash(scroll: controller),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('the light masthead keeps the warm wash', (tester) async {
      await pumpWash(tester, AppTheme.createTheme(Brightness.light));
      expect(find.byKey(const Key('detail_masthead_wash')), findsOneWidget);
    });

    testWidgets('the dark masthead keeps the warm wash', (tester) async {
      await pumpWash(tester, AppTheme.createTheme(Brightness.dark));
      expect(find.byKey(const Key('detail_masthead_wash')), findsOneWidget);
    });

    testWidgets('the e-ink masthead stays pure white', (tester) async {
      einkModeNotifier.value = true;
      await pumpWash(
        tester,
        AppTheme.createTheme(Brightness.light, einkMode: true),
      );
      expect(find.byKey(const Key('detail_masthead_wash')), findsNothing);
    });
  });
}
