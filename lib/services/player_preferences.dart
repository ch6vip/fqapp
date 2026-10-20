import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PlayerPreferences {
  static const _playbackRateKey = 'player_playback_rate';
  static const _autoAdvanceKey = 'player_auto_advance';
  static const _floatingWindowKey = 'player_floating_window_enabled';
  static Future<void>? _autoAdvanceWrites;

  /// 切后台悬浮窗播放（#24，默认关）：开启且已授予悬浮窗权限时，切到
  /// 后台或锁屏用悬浮小窗继续播；关闭则切后台暂停（现有行为）。
  static final ValueNotifier<bool> floatingWindow = ValueNotifier<bool>(false);
  static bool _floatingLoaded = false;

  static Future<void> loadFloatingWindow() async {
    if (_floatingLoaded) return;
    _floatingLoaded = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      floatingWindow.value = preferences.getBool(_floatingWindowKey) ?? false;
    } catch (_) {
      // 异常时退回默认关闭
    }
  }

  /// 重置测试状态，让下一次 [loadFloatingWindow] 重新读取。
  @visibleForTesting
  static void resetFloatingWindowForTest() {
    _floatingLoaded = false;
    floatingWindow.value = false;
  }

  static Future<void> setFloatingWindow(bool enabled) async {
    floatingWindow.value = enabled;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_floatingWindowKey, enabled);
    } catch (_) {
      // 忽略持久化失败
    }
  }

  /// 官方 `player_control_panel_opt_v645.playrate_list` 的实测档位（用户设备
  /// 官方截图 + 横屏子列表证据）：含 2x/3x，**没有 1.75x**。
  static const playbackRates = <double>[0.75, 1, 1.25, 1.5, 2, 3];

  /// 视频解码器选择（issue #92）。
  ///
  /// 联发科部分芯片在 Android 15 上播 HEVC + 加密内容时硬解黑屏/卡帧，且
  /// **不抛任何错误**（androidx/media#2711、Google issue 437738589），
  /// `setEnableDecoderFallback` 因此救不了，只能让用户手动切软解。默认仍是
  /// 系统自动选择，不替所有设备做取舍。
  static const _videoDecoderKey = 'player_video_decoder';

  static Future<VideoDecoderPreference> loadVideoDecoder() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getString(_videoDecoderKey);
    return VideoDecoderPreference.values.firstWhere(
      (value) => value.name == saved,
      orElse: () => VideoDecoderPreference.automatic,
    );
  }

  static Future<void> saveVideoDecoder(VideoDecoderPreference value) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(_videoDecoderKey, value.name)) {
      throw StateError('Could not save the video decoder preference');
    }
  }
  static Future<double> loadPlaybackRate() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.get(_playbackRateKey);
    return normalizePlaybackRate(saved is num ? saved.toDouble() : 1);
  }

  static Future<void> savePlaybackRate(double rate) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(_playbackRateKey, normalizePlaybackRate(rate));
  }

  static Future<bool> loadAutoAdvance() async {
    final pending = _autoAdvanceWrites;
    if (pending != null) await pending;
    final preferences = await SharedPreferences.getInstance();
    return preferences.get(_autoAdvanceKey) is bool
        ? preferences.getBool(_autoAdvanceKey)!
        : true;
  }

  static Future<void> saveAutoAdvance(bool enabled) {
    // Share the queue across pages so immediate exit/reentry cannot reorder
    // a previous page's writes after the user's newer choice.
    final write = (_autoAdvanceWrites ?? Future<void>.value()).then((_) async {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setBool(_autoAdvanceKey, enabled)) {
        throw StateError('Could not save automatic episode playback');
      }
    });
    late final Future<void> settled;
    settled = write.catchError((Object _) {}).whenComplete(() {
      if (identical(_autoAdvanceWrites, settled)) _autoAdvanceWrites = null;
    });
    _autoAdvanceWrites = settled;
    return write;
  }
}

/// 视频解码器偏好。
///
/// [automatic] 交给 ExoPlayer 自己挑（默认，硬解优先）；[software] 只在用户
/// 明确遇到硬解异常时选用——软解对所有分辨率都更耗电，不能当默认。
enum VideoDecoderPreference {
  automatic('自动'),
  hardware('硬解'),
  software('软解');

  const VideoDecoderPreference(this.label);

  /// 设置项展示用文案。
  final String label;
}


/// 解码器偏好的进程内缓存。
///
/// `NativePlayer.create` 在起播关键路径上，不能 `await` 读盘：等待
/// SharedPreferences 会在插件未就绪时挂住整个起播（单元测试里直接超时）。
/// 启动时读一次，设置页改动后再写入，`create` 只读这里的内存值。
class DecoderPreferenceCache {
  DecoderPreferenceCache._();

  static VideoDecoderPreference current = VideoDecoderPreference.automatic;

  /// 从磁盘载入；失败保持 [automatic]，不阻塞调用方。
  static Future<void> load() async {
    try {
      current = await PlayerPreferences.loadVideoDecoder();
    } catch (_) {
      current = VideoDecoderPreference.automatic;
    }
  }

  /// 先落盘再更新内存：写失败时内存值不变，避免界面显示已生效而播放器没变。
  static Future<void> set(VideoDecoderPreference value) async {
    await PlayerPreferences.saveVideoDecoder(value);
    current = value;
  }
}
double normalizePlaybackRate(double value) {
  if (!value.isFinite || value <= 0) return 1;
  return PlayerPreferences.playbackRates.reduce(
    (best, candidate) =>
        (candidate - value).abs() < (best - value).abs() ? candidate : best,
  );
}
