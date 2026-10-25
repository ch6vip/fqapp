import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
  });

  tearDown(() => AudioPreferences.instance.resetForTest());

  // issue #129：听书高倍速的电音/金属感来自 Media3 内建的 Sonic 时伸缩，
  // 默认改用系统混音器后，万一某个厂商实现异常也得能退回内建变速——所以
  // 设置 → 听书里必须有一个可切换的入口，且选择要落盘。
  testWidgets('听书变速引擎可在两档间切换并持久化', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.tap(find.text('听书'));
    await tester.pumpAndSettle();

    expect(find.text('听书变速引擎'), findsOneWidget);
    expect(find.text(AudioRateEngine.wsola.label), findsOneWidget);

    await tester.tap(find.text('听书变速引擎'));
    await tester.pumpAndSettle();
    expect(
      find.text('与番茄官方同一套算法（FFmpeg atempo），高倍速听感最接近原声（默认）'),
      findsOneWidget,
    );

    await tester.tap(find.text(AudioRateEngine.builtIn.label));
    await tester.pumpAndSettle();

    expect(AudioPreferences.instance.rateEngine.value, AudioRateEngine.builtIn);
    expect(find.text(AudioRateEngine.builtIn.label), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('audio_rate_engine'), 'builtIn');
  });
}
