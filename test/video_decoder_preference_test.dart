import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // issue #92: 硬解异常的机型需要能手动切软解，且选择要跨启动保留。
  test('defaults to automatic when nothing was saved', () async {
    expect(
      await PlayerPreferences.loadVideoDecoder(),
      VideoDecoderPreference.automatic,
    );
    expect(DecoderPreferenceCache.current, VideoDecoderPreference.automatic);
  });

  test('saves and reloads the software choice', () async {
    await PlayerPreferences.saveVideoDecoder(VideoDecoderPreference.software);
    expect(
      await PlayerPreferences.loadVideoDecoder(),
      VideoDecoderPreference.software,
    );
  });

  test('an unknown stored value falls back to automatic', () async {
    SharedPreferences.setMockInitialValues({
      'player_video_decoder': 'turbo',
    });
    expect(
      await PlayerPreferences.loadVideoDecoder(),
      VideoDecoderPreference.automatic,
    );
  });

  test('cache mirrors the saved value so create() can read it synchronously', () async {
    await DecoderPreferenceCache.set(VideoDecoderPreference.software);
    expect(DecoderPreferenceCache.current, VideoDecoderPreference.software);
    // 落盘与内存必须一致，否则重启后又回到硬解。
    expect(
      await PlayerPreferences.loadVideoDecoder(),
      VideoDecoderPreference.software,
    );
  });

  test('load() populates the cache from disk', () async {
    SharedPreferences.setMockInitialValues({
      'player_video_decoder': 'hardware',
    });
    await DecoderPreferenceCache.load();
    expect(DecoderPreferenceCache.current, VideoDecoderPreference.hardware);
  });
}
