import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/system_tts_settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/widgets/settings/settings_archive_page.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

/// 系统朗读设置页的空态 / 错态走统一的 [ContentNotice]（Wenku8 档案态），
/// 页面骨架走设置页共享的 [SettingsArchivePage]（档案主题下等价于
/// `ArchiveFeaturePage`，经典主题下换成经典 AppBar 外壳）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fqapp/system_tts');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    einkModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.light;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    einkModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Future<Object?> Function(MethodCall call) handler, {
    AppThemeStyle style = AppThemeStyle.archive,
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light, style: style),
        home: const SystemTtsSettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final style in AppThemeStyle.values) {
    for (final platform in [TargetPlatform.linux, TargetPlatform.android]) {
      testWidgets('$style $platform 语音设置动作符合平台能力', (tester) async {
        const guidance =
            '请使用系统 Speech Dispatcher 配置工具配置中文语音（例如 '
            'espeak-ng），然后重新初始化。';
        var settingsRequests = 0;
        await pumpPage(tester, (call) async {
          if (call.method == 'engines') {
            return {'engines': <Object?>[], 'defaultEngine': null};
          }
          if (call.method == 'settings') {
            settingsRequests++;
            expect(call.arguments, isNull);
            if (platform == TargetPlatform.linux) {
              throw PlatformException(code: 'TTS_ERROR', message: guidance);
            }
          }
          return null;
        }, style: style);

        final label = platform == TargetPlatform.linux
            ? '查看语音配置指引'
            : '打开系统语音设置';
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();

        expect(settingsRequests, 1);
        expect(find.byType(SnackBar), findsNothing);
        if (platform == TargetPlatform.linux) {
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.text('语音配置指引'), findsOneWidget);
          expect(find.text(guidance), findsOneWidget);
          expect(find.text('打开系统语音设置'), findsNothing);
          await tester.tap(find.text('知道了'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
        } else {
          expect(find.byType(AlertDialog), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant({platform}));
    }
  }

  testWidgets('没有朗读引擎时展示 ContentNotice 空态', (tester) async {
    await pumpPage(tester, (call) async {
      if (call.method == 'engines') {
        return {'engines': <Object?>[], 'defaultEngine': null};
      }
      return null;
    });

    expect(find.byType(SettingsArchivePage), findsOneWidget);
    expect(find.byType(ContentNotice), findsOneWidget);
    expect(find.text('没有找到朗读引擎'), findsOneWidget);
    expect(find.textContaining('请先安装'), findsOneWidget);
  });

  testWidgets('读取引擎失败时展示 ContentNotice 错态并可重试', (tester) async {
    var attempts = 0;
    await pumpPage(tester, (call) async {
      if (call.method == 'engines') {
        attempts++;
        if (attempts == 1) {
          throw PlatformException(
            code: 'engine_unavailable',
            message: '引擎读取失败',
          );
        }
        return {'engines': <Object?>[], 'defaultEngine': null};
      }
      return null;
    });

    expect(find.byType(ContentNotice), findsOneWidget);
    expect(find.text('无法读取朗读引擎'), findsOneWidget);
    expect(find.text('引擎读取失败'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('没有找到朗读引擎'), findsOneWidget);
  });
}
