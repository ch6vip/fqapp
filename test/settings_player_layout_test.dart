import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/player_layout_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlayerLayoutPreferences.mode.value = PlayerLayoutMode.immersive;
    themeModeNotifier.value = ThemeMode.light;
  });

  tearDown(() {
    PlayerLayoutPreferences.mode.value = PlayerLayoutMode.immersive;
    themeModeNotifier.value = ThemeMode.system;
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> mountSettings(
    WidgetTester tester, {
    Size window = const Size(430, 900),
  }) async {
    await tester.binding.setSurfaceSize(window);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('外观分类里的播放页布局三选一并落盘', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await mountSettings(tester);
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();

      expect(find.text('播放页布局'), findsOneWidget);
      // 行尾先显示当前选择（默认沉浸式）。
      expect(find.text('沉浸式'), findsOneWidget);

      await tester.tap(find.text('播放页布局'));
      await tester.pumpAndSettle();

      // 行标题 + 弹层标题各一个。
      expect(find.text('播放页布局'), findsNWidgets(2));
      for (final mode in PlayerLayoutMode.values) {
        expect(find.text(mode.label), findsWidgets);
        expect(find.text(mode.description), findsOneWidget);
      }

      await tester.tap(find.text('始终分屏'));
      await tester.pumpAndSettle();

      expect(PlayerLayoutPreferences.mode.value, PlayerLayoutMode.split);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString(PlayerLayoutPreferences.key), 'split');
      // 弹层关闭后行尾跟随新选择，旧的「沉浸式」不再出现。
      expect(find.text('始终分屏'), findsOneWidget);
      expect(find.text('沉浸式'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('选择与当前一致时不重复落盘也不报错', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      PlayerLayoutPreferences.mode.value = PlayerLayoutMode.auto;
      await mountSettings(tester);
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      expect(find.text('自动分屏'), findsOneWidget);

      await tester.tap(find.text('播放页布局'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('横屏片源自动分屏'));
      await tester.pumpAndSettle();

      // 早退分支：偏好不变，也没有失败提示。
      expect(PlayerLayoutPreferences.mode.value, PlayerLayoutMode.auto);
      expect(find.text('自动分屏'), findsOneWidget);
      expect(find.text('未能保存播放页布局，已恢复原设置'), findsNothing);
      // 真正的「不重复落盘」：SP 里仍是初始的「未写入」状态。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PlayerLayoutPreferences.key), isNull);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('桌面端不提供播放页布局入口', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await mountSettings(tester, window: const Size(1280, 800));
      // Windows 走桌面设置台，默认侧栏已选中外观。
      expect(find.text('主题模式'), findsOneWidget);
      expect(find.text('播放页布局'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
