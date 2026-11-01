import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/system_tts_settings_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/home/home_feed_states.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';

/// 系统朗读设置页的空态 / 错态不再是一行裸 Text，而是统一的 [HomeStateView]。
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
    Future<Object?> Function(MethodCall call) handler,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const SystemTtsSettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有朗读引擎时展示 HomeStateView 空态', (tester) async {
    await pumpPage(tester, (call) async {
      if (call.method == 'engines') {
        return {'engines': <Object?>[], 'defaultEngine': null};
      }
      return null;
    });

    expect(find.byType(SettingsScaffold), findsOneWidget);
    expect(find.byType(HomeStateView), findsOneWidget);
    expect(find.text('没有找到朗读引擎'), findsOneWidget);
    expect(find.textContaining('请先安装'), findsOneWidget);
  });

  testWidgets('读取引擎失败时展示 HomeStateView 错态并可重试', (tester) async {
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

    expect(find.byType(HomeStateView), findsOneWidget);
    expect(find.text('无法读取朗读引擎'), findsOneWidget);
    expect(find.text('引擎读取失败'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('没有找到朗读引擎'), findsOneWidget);
  });
}
