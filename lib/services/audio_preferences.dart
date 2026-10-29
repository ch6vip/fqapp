import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 听书相关配置与持久化偏好设置。
class AudioPreferences {
  AudioPreferences._();

  static final AudioPreferences instance = AudioPreferences._();

  static const _backgroundPlaybackKey = 'audio_background_playback_enabled';
  static const _rateEngineKey = 'audio_rate_engine';

  /// 倍速锁定：锁定后点倍速项不再弹面板（官方 `a4g`「已经锁定2x倍速」）。
  static const _rateLockedKey = 'audio_rate_locked';

  /// 睡眠定时选的是「听完本章」而不是分钟档（官方 `cip`）。
  static const _sleepAtChapterEndKey = 'audio_sleep_at_chapter_end';

  /// 跳过片头 / 片尾按书存，单位秒；没有记录就是 0（不跳）。
  static const _skipIntroPrefix = 'audio_skip_intro_';
  static const _skipOutroPrefix = 'audio_skip_outro_';

  /// 是否允许后台播放与前台保活（默认 true）。
  /// 开启：切到后台或锁屏时继续播放，由 Android 前台保活服务常驻通知栏与提供控制卡片；
  /// 关闭：切到后台或锁屏时自动暂停播放并移除前台通知。
  final ValueNotifier<bool> backgroundPlayback = ValueNotifier<bool>(true);

  /// 听书倍速的变速实现（issue #129 / #170）。
  ///
  /// 默认 [AudioRateEngine.builtIn]（Media3 内建 Sonic），也就是 1.0.121
  /// 及更早版本的行为。1.0.133 把默认改成 [AudioRateEngine.wsola]（移植的
  /// FFmpeg `atempo`）后，部分设备听书一直停在「缓冲中」没有任何声音
  /// （issue #170）；在真机验证 WSOLA 之前先退回内建实现，用户仍可在
  /// 设置 → 听书里手动选 WSOLA 获得更接近官方的听感。
  final ValueNotifier<AudioRateEngine> rateEngine = ValueNotifier(
    AudioRateEngine.builtIn,
  );

  /// 倍速是否已锁定。锁定期间点倍速项只提示、不弹面板。
  bool rateLocked = false;

  /// 睡眠定时是否停在「听完本章」。与分钟档互斥。
  bool sleepAtChapterEnd = false;

  final Map<String, int> _skipIntro = <String, int>{};
  final Map<String, int> _skipOutro = <String, int>{};
  final Set<String> _skipLoaded = <String>{};

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      backgroundPlayback.value = sp.getBool(_backgroundPlaybackKey) ?? true;
      rateEngine.value = AudioRateEngine.fromName(sp.getString(_rateEngineKey));
      rateLocked = sp.getBool(_rateLockedKey) ?? false;
      sleepAtChapterEnd = sp.getBool(_sleepAtChapterEndKey) ?? false;
    } catch (_) {
      // 异常时退回默认值（后台播放开、系统变速、未锁定、分钟档）
    }
  }

  /// 重置测试状态，让下一次 [load] 重新读取 SharedPreferences。
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    backgroundPlayback.value = true;
    rateEngine.value = AudioRateEngine.builtIn;
    rateLocked = false;
    sleepAtChapterEnd = false;
    _skipIntro.clear();
    _skipOutro.clear();
    _skipLoaded.clear();
  }

  /// 把这本书的跳过片头/片尾读进内存（控制器需要在开章时同步读）。
  Future<void> ensureSkipPoints(String bookId) async {
    if (bookId.isEmpty || _skipLoaded.contains(bookId)) return;
    _skipLoaded.add(bookId);
    try {
      final sp = await SharedPreferences.getInstance();
      _skipIntro[bookId] = sp.getInt('$_skipIntroPrefix$bookId') ?? 0;
      _skipOutro[bookId] = sp.getInt('$_skipOutroPrefix$bookId') ?? 0;
    } catch (_) {
      _skipIntro[bookId] = 0;
      _skipOutro[bookId] = 0;
    }
  }

  int skipIntroSeconds(String bookId) => _skipIntro[bookId] ?? 0;

  int skipOutroSeconds(String bookId) => _skipOutro[bookId] ?? 0;

  Future<void> setSkipIntroSeconds(String bookId, int seconds) async {
    final value = seconds < 0 ? 0 : seconds;
    _skipIntro[bookId] = value;
    _skipLoaded.add(bookId);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('$_skipIntroPrefix$bookId', value);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  Future<void> setSkipOutroSeconds(String bookId, int seconds) async {
    final value = seconds < 0 ? 0 : seconds;
    _skipOutro[bookId] = value;
    _skipLoaded.add(bookId);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('$_skipOutroPrefix$bookId', value);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  Future<void> setRateLocked(bool value) async {
    rateLocked = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_rateLockedKey, value);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  Future<void> setSleepAtChapterEnd(bool value) async {
    sleepAtChapterEnd = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_sleepAtChapterEndKey, value);
    } catch (_) {
      // 忽略持久化失败
    }
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
  /// 移植自官方 FFmpeg `af_atempo` 的 WSOLA（可选，1.0.133 起默认开启过，
  /// 因 issue #170 的静音问题暂时退回内建实现）。
  ///
  /// 番茄 7.0.9.32 的听书倍速走的就是这条路：native 层
  /// `avfilter_get_by_name("atempo")`、参数 `tempo=%1.2f`。窗口
  /// `sample_rate/24`、Hann 窗重叠相加、FFT 互相关对齐，听感与官方一致。
  wsola('对齐官方'),

  /// 系统混音器变速（AudioTrack/APM）。不依赖我们的 native 库。
  platform('系统'),

  /// Media3 内建 Sonic 变速。默认项（1.0.121 及更早的行为）。
  builtIn('兼容');

  const AudioRateEngine(this.label);

  /// 设置项展示用文案。
  final String label;

  static AudioRateEngine fromName(String? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => AudioRateEngine.builtIn,
  );
}
