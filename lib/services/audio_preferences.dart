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
  /// 默认 [AudioRateEngine.wsola]：番茄官方听书倍速走的也是 FFmpeg
  /// `atempo`（见 `dn2`/`libttmplayer.so` 的取证），本仓库用移植后的同一份
  /// 算法，因此听感最接近官方。另有 [AudioRateEngine.platform]（系统混音器）
  /// 与 [AudioRateEngine.builtIn]（Media3 Sonic）两个回退档。
  final ValueNotifier<AudioRateEngine> rateEngine = ValueNotifier(
    AudioRateEngine.wsola,
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
    rateEngine.value = AudioRateEngine.wsola;
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
  /// 移植自官方 FFmpeg `af_atempo` 的 WSOLA（默认）。
  ///
  /// 番茄 7.0.9.32 的听书倍速走的就是这条路：native 层
  /// `avfilter_get_by_name("atempo")`、参数 `tempo=%1.2f`。窗口
  /// `sample_rate/24`、Hann 窗重叠相加、FFT 互相关对齐，听感与官方一致。
  wsola('对齐官方'),

  /// 系统混音器变速（AudioTrack/APM）。不依赖我们的 native 库。
  platform('系统'),

  /// Media3 内建 Sonic 变速。最后的保底项（改动前的行为）。
  builtIn('兼容');

  const AudioRateEngine(this.label);

  /// 设置项展示用文案。
  final String label;

  static AudioRateEngine fromName(String? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => AudioRateEngine.wsola,
  );
}
