import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/app_ui_host.dart';

/// #315：当前主题在三套设置首页（档案手机、经典手机、Windows 双栏）都用
/// 右侧值展示，副标题固定为说明文字，不再被当前值替换或丢失。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.light;
    AppThemeStyleStore.instance.value = AppThemeStyle.archive;
  });

  tearDown(() {
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
    AppThemeStyleStore.instance.value = AppThemeStyle.archive;
  });

  Future<void> pumpSettings(WidgetTester tester, AppThemeStyle style) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // SettingsPage reads the app-wide store for the value; AppUiHost drives
    // the presentation from its own store.
    AppThemeStyleStore.instance.value = style;
    final store = AppThemeStyleStore()..value = style;
    addTearDown(store.dispose);
    await tester.pumpWidget(
      AppUiHost(store: store, home: const SettingsPage()),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('档案主题首页把当前主题放在右侧值', (tester) async {
    await pumpSettings(tester, AppThemeStyle.archive);

    final entry = tester.widget<FeatureEntry>(
      find.byWidgetPredicate((w) => w is FeatureEntry && w.title == '主题'),
    );
    expect(entry.subtitle, '经典主题、档案主题');
    expect(entry.trailingText, '档案主题');
  });

  testWidgets('经典主题首页用同样的右侧值，副标题保持说明', (tester) async {
    await pumpSettings(tester, AppThemeStyle.classic);

    final row = tester.widget<SettingsRow>(
      find.byWidgetPredicate((w) => w is SettingsRow && w.title == '主题'),
    );
    expect(row.subtitle, '经典主题、档案主题');
    expect(row.value, '经典主题');
  });

  testWidgets('Windows 双栏也在右侧显示当前主题', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      AppThemeStyleStore.instance.value = AppThemeStyle.archive;
      final store = AppThemeStyleStore()..value = AppThemeStyle.archive;
      addTearDown(store.dispose);
      await tester.pumpWidget(
        AppUiHost(store: store, home: const SettingsPage()),
      );
      await tester.pumpAndSettle();

      final rowFinder = find.byWidgetPredicate(
        (w) => w is SettingsRow && w.title == '主题',
      );
      expect(rowFinder, findsOneWidget);
      expect(tester.widget<SettingsRow>(rowFinder).subtitle, '经典主题、档案主题');
      expect(
        find.descendant(of: rowFinder, matching: find.text('档案主题')),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
