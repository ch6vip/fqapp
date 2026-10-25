import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
  });

  test('defaults to background playback enabled', () async {
    expect(AudioPreferences.instance.backgroundPlayback.value, true);
    await AudioPreferences.instance.load();
    expect(AudioPreferences.instance.backgroundPlayback.value, true);
  });

  test('loads saved background playback preference when false', () async {
    SharedPreferences.setMockInitialValues({
      'audio_background_playback_enabled': false,
    });
    await AudioPreferences.instance.load();
    expect(AudioPreferences.instance.backgroundPlayback.value, false);
  });

  test('saves and persists background playback preference', () async {
    await AudioPreferences.instance.setBackgroundPlayback(false);
    expect(AudioPreferences.instance.backgroundPlayback.value, false);

    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('audio_background_playback_enabled'), false);

    AudioPreferences.instance.resetForTest();
    await AudioPreferences.instance.load();
    expect(AudioPreferences.instance.backgroundPlayback.value, false);
  });

  // issue #129：默认用系统混音器变速（听感更接近 1.0×），但保留内建 Sonic
  // 作为回退档——系统实现依赖厂商 AudioFlinger/APM。
  test('defaults the listen-mode rate engine to the official WSOLA', () async {
    // issue #129：默认必须是与番茄官方同源的 WSOLA（FFmpeg atempo 移植），
    // 否则高倍速又会退回「电音」的内建 Sonic。
    expect(
      AudioPreferences.instance.rateEngine.value,
      AudioRateEngine.wsola,
    );
    await AudioPreferences.instance.load();
    expect(
      AudioPreferences.instance.rateEngine.value,
      AudioRateEngine.wsola,
    );
  });

  test('loads and persists the saved rate engine', () async {
    await AudioPreferences.instance.setRateEngine(AudioRateEngine.builtIn);
    expect(AudioPreferences.instance.rateEngine.value, AudioRateEngine.builtIn);

    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('audio_rate_engine'), 'builtIn');

    AudioPreferences.instance.resetForTest();
    expect(
      AudioPreferences.instance.rateEngine.value,
      AudioRateEngine.wsola,
    );
    await AudioPreferences.instance.load();
    expect(AudioPreferences.instance.rateEngine.value, AudioRateEngine.builtIn);
  });

  test(
    'unknown persisted rate engine names fall back to WSOLA',
    () async {
      SharedPreferences.setMockInitialValues({'audio_rate_engine': 'turbo'});
      await AudioPreferences.instance.load();
      expect(
        AudioPreferences.instance.rateEngine.value,
        AudioRateEngine.wsola,
      );
    },
  );

  test('dart and kotlin rate engine names stay in sync', () {
    // Kotlin 侧 AudioRateEngine 用 wireName 逐字解析（BUILT_IN ↔ builtIn），
    // 改一处必须同步另一处。
    expect(AudioRateEngine.values.map((value) => value.name), [
      'wsola',
      'platform',
      'builtIn',
    ]);
  });
}
