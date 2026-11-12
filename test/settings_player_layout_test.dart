import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/pages/settings_category_page.dart';
import 'package:fqapp/pages/system_tts_settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/player_layout_preferences.dart';
import 'package:fqapp/widgets/desktop_settings_body.dart';
import 'package:fqapp/widgets/wenku/wenku_overlay.dart';

import 'support/app_ui_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    PlayerLayoutPreferences.mode.value = PlayerLayoutMode.immersive;
    themeModeNotifier.value = ThemeMode.light;
  });

  tearDown(() {
    AudioPreferences.instance.resetForTest();
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

  // 设置菜单选项在弹层里的定位：行内 selector 与菜单项可能显示同一个文案。
  Finder menuOption(String label) => find.descendant(
    of: find.byType(GlassMenuItem),
    matching: find.text(label),
  );

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

      // 上游 GlassSettingMenu 没有弹层标题，直接列出选项。
      for (final mode in PlayerLayoutMode.values) {
        expect(menuOption(mode.label), findsOneWidget);
      }

      await tester.tap(menuOption('始终分屏'));
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
      // 行内保留短标签，弹层里仍是完整标签。
      expect(find.text('自动分屏'), findsOneWidget);

      await tester.tap(find.text('播放页布局'));
      await tester.pumpAndSettle();
      expect(menuOption('自动适配布局'), findsOneWidget);
      expect(find.text('自动分屏'), findsOneWidget);
      await tester.tap(menuOption('自动适配布局'));
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

  for (final style in AppThemeStyle.values) {
    testWidgets('Linux ${style.name} 隐藏手机设置并保留后台听书与系统朗读', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        SharedPreferences.setMockInitialValues({
          PlayerLayoutPreferences.key: 'split',
          'audio_rate_engine': 'wsola',
          'player_floating_window_enabled': true,
          'player_video_decoder': 'software',
          'drama_mute_when_cold_start': true,
        });
        final store = AppThemeStyleStore()..value = style;
        addTearDown(store.dispose);
        await tester.binding.setSurfaceSize(const Size(430, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        const ttsChannel = MethodChannel('fqapp/system_tts');
        final messenger = tester.binding.defaultBinaryMessenger;
        var engineQueries = 0;
        messenger.setMockMethodCallHandler(ttsChannel, (call) async {
          if (call.method == 'engines') {
            engineQueries++;
            return {'engines': <Object?>[], 'defaultEngine': null};
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(ttsChannel, null));
        await tester.pumpWidget(
          AppUiHost(store: store, home: const SettingsPage()),
        );
        await tester.pumpAndSettle();
        expect(find.byType(DesktopSettingsBody), findsNothing);
        expect(find.text('主题模式、OLED 纯黑'), findsOneWidget);
        expect(find.text('短剧'), findsNothing);

        await tester.tap(find.text('外观'));
        await tester.pumpAndSettle();
        expect(find.text('主题模式'), findsOneWidget);
        expect(find.text('播放页布局'), findsNothing);
        Navigator.of(tester.element(find.byType(SettingsCategoryPage))).pop();
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('数据'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('数据'));
        await tester.pumpAndSettle();
        expect(find.text('短剧离线缓存'), findsOneWidget);
        expect(find.text('管理已下载文件和下载任务'), findsOneWidget);
        Navigator.of(tester.element(find.byType(SettingsCategoryPage))).pop();
        await tester.pumpAndSettle();

        await tester.tap(find.text('听书'));
        await tester.pumpAndSettle();
        expect(find.text('听书变速引擎'), findsNothing);
        expect(find.text('后台听书与保活'), findsOneWidget);
        await tester.tap(find.text('后台听书与保活'));
        await tester.pumpAndSettle();
        expect(AudioPreferences.instance.backgroundPlayback.value, isFalse);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('audio_background_playback_enabled'), isFalse);
        expect(prefs.getString(PlayerLayoutPreferences.key), 'split');
        expect(prefs.getString('audio_rate_engine'), 'wsola');
        expect(prefs.getBool('player_floating_window_enabled'), isTrue);
        expect(prefs.getString('player_video_decoder'), 'software');
        expect(prefs.getBool('drama_mute_when_cold_start'), isTrue);

        await tester.tap(find.text('系统朗读'));
        await tester.pumpAndSettle();
        expect(find.byType(SystemTtsSettingsPage), findsOneWidget);
        expect(engineQueries, 1);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

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
