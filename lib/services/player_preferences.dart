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

double normalizePlaybackRate(double value) {
  if (!value.isFinite || value <= 0) return 1;
  return PlayerPreferences.playbackRates.reduce(
    (best, candidate) =>
        (candidate - value).abs() < (best - value).abs() ? candidate : best,
  );
}
