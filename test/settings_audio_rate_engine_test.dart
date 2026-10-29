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

  // issue #129 / #170：听书高倍速的电音/金属感来自 Media3 内建的 Sonic 时伸缩，
  // 但 1.0.133 把默认换成 WSOLA 后部分设备一直「缓冲中」没有任何声音，所以默认
  // 退回内建 Sonic，WSOLA 仍可在设置里手动选择并落盘。
  testWidgets('听书变速引擎默认内建 Sonic，可切到 WSOLA 并持久化', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.tap(find.text('听书'));
    await tester.pumpAndSettle();

    expect(find.text('听书变速引擎'), findsOneWidget);
    expect(find.text(AudioRateEngine.builtIn.label), findsOneWidget);

    await tester.tap(find.text('听书变速引擎'));
    await tester.pumpAndSettle();
    expect(find.text('Media3 内建 Sonic，最稳（默认，1.0.121 的行为）'), findsOneWidget);

    await tester.tap(find.text(AudioRateEngine.wsola.label));
    await tester.pumpAndSettle();

    expect(AudioPreferences.instance.rateEngine.value, AudioRateEngine.wsola);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('audio_rate_engine'), 'wsola');
  });
}
