import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 听书相关配置与持久化偏好设置。
class AudioPreferences {
  AudioPreferences._();

  static final AudioPreferences instance = AudioPreferences._();

  static const _backgroundPlaybackKey = 'audio_background_playback_enabled';
  static const _rateEngineKey = 'audio_rate_engine';

  /// 是否允许后台播放与前台保活（默认 true）。
  /// 开启：切到后台或锁屏时继续播放，由 Android 前台保活服务常驻通知栏与提供控制卡片；
  /// 关闭：切到后台或锁屏时自动暂停播放并移除前台通知。
  final ValueNotifier<bool> backgroundPlayback = ValueNotifier<bool>(true);

  /// 听书倍速的变速实现（issue #129）。
  ///
  /// 默认 [AudioRateEngine.platform]：倍速交给系统音频混音器
  /// （AudioTrack/APM，Media3 的 `setEnableAudioTrackPlaybackParams`）。
  /// 实测同一段语音 2.0×，Media3 内建 Sonic 的谐噪比比系统实现低 2.9 dB
  /// ——即用户听到的「电音/金属感」。失败时可以退回 [builtIn]
  /// （Media3 SonicAudioProcessor，不依赖系统实现）。
  final ValueNotifier<AudioRateEngine> rateEngine = ValueNotifier(
    AudioRateEngine.platform,
  );

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      backgroundPlayback.value = sp.getBool(_backgroundPlaybackKey) ?? true;
      rateEngine.value = AudioRateEngine.fromName(sp.getString(_rateEngineKey));
    } catch (_) {
      // 异常时退回默认值（后台播放开、系统变速）
    }
  }

  /// 重置测试状态，让下一次 [load] 重新读取 SharedPreferences。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    backgroundPlayback.value = true;
    rateEngine.value = AudioRateEngine.platform;
  }

  Future<void> setBackgroundPlayback(bool value) async {
    backgroundPlayback.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_backgroundPlaybackKey, value);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  /// 变速引擎在**新建播放器**时生效：Media3 的 audio sink 在 build 时就
  /// 定型了，和「视频解码器」一样需要重新进入听书页。
  Future<void> setRateEngine(AudioRateEngine value) async {
    rateEngine.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_rateEngineKey, value.name);
    } catch (_) {
      // 忽略持久化失败
    }
  }
}

/// 听书变速引擎的进程内缓存。
///
/// `NativePlayer.create` 在起播关键路径上，不能 `await` 读盘（理由见
/// `DecoderPreferenceCache`）。[AudioPreferences.rateEngine] 是同一个值
/// 的唯一来源，这里只是在没有初始化偏好时给 create 一个安全默认值。
class AudioRateEngineCache {
  AudioRateEngineCache._();

  static AudioRateEngine get current =>
      AudioPreferences.instance.rateEngine.value;
}

/// 听书倍速的变速实现。
///
/// `name`（platform / builtIn）就是跨端的协议名：Kotlin 侧 `AudioRateEngine`
/// 用 `wireName` 逐字解析（BUILT_IN 这个常量名不上线），改一处必须同步另一处。
enum AudioRateEngine {
  /// 系统混音器变速（AudioTrack/APM）。Android 可闻更接近 1.0× 原声。
  platform('系统'),

  /// Media3 内建 Sonic 变速。不依赖系统实现，保底选项。
  builtIn('兼容');

  const AudioRateEngine(this.label);

  /// 设置项展示用文案。
  final String label;

  static AudioRateEngine fromName(String? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => AudioRateEngine.platform,
  );
}
