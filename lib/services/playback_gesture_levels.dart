import 'package:flutter/services.dart';

import 'platform_channel.dart';

/// 播放页上下滑手势的设备档位：窗口亮度与媒体音量，都归一化到 0..1。
///
/// 手势本身在 [VideoPlayerChrome] 里识别（分屏视频盒左半 = 亮度、右半 =
/// 音量），这里只负责读写 Android 侧的窗口/音频档位。没有原生桥（桌面、
/// 测试环境未 mock）时全部退化为 null / no-op，界面不会报错。
class PlaybackGestureLevels {
  static const _channel = AppMethodChannel('fqapp/native_player');

  /// 读当前档位；拿不到时返回 null。
  ///
  /// `volumeSteps` 是设备的音量档数（本机 160），HUD 用它把连续百分比量化
  /// 成同一档位，避免「显示 37% 实际落在第 59 档」的偏差；老版本原生桥不带
  /// 这个字段时回 0，Dart 侧退化为按百分比显示。
  static Future<({double brightness, double volume, int volumeSteps})?>
  read() async {
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        'gestureLevels',
      );
      final brightness = value?['brightness'];
      final volume = value?['volume'];
      if (brightness is! num || volume is! num) return null;
      final steps = value?['volumeSteps'];
      return (
        brightness: brightness.toDouble().clamp(0.0, 1.0),
        volume: volume.toDouble().clamp(0.0, 1.0),
        volumeSteps: steps is num && steps > 0 ? steps.toInt() : 0,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 覆盖当前窗口亮度（0..1）。
  static Future<void> setBrightness(double value) =>
      _invokeQuietly('setScreenBrightness', value);

  /// 还原进入播放页前的窗口亮度。
  static Future<void> resetBrightness() =>
      _invokeQuietly('resetScreenBrightness', null);

  /// 设置媒体音量档位（0..1）。
  static Future<void> setVolume(double value) =>
      _invokeQuietly('setMediaVolume', value);

  static Future<void> _invokeQuietly(String method, double? value) async {
    try {
      // reset 不需要 value；其余方法一律带一个 0..1 的档位。
      final arguments = value == null ? null : <String, double>{'value': value};
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // 没有原生桥：手势无效但不影响播放。
    } on PlatformException {
      // Activity 重建等瞬时失败：下一次手势会重新下发。
    }
  }
}
