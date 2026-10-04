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
}
