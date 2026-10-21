import 'platform_channel.dart';
import 'package:flutter/services.dart';

/// 音量键翻页桥。封装原生通道 `fqapp/volume-key`：
///
/// - [setEnabled]：阅读页且开启“音量键翻页”时通知原生拦截音量键；
///   关闭（离开阅读页 / 显示控制栏 / 未开启）时放行系统音量。
/// - 原生拦截到音量键后，通过 `volumeKey` 回调把方向（+1 下一页 / -1 上一页）
///   传回 Dart，由阅读页执行翻页。
///
/// 与 Flutter 的 [HardwareKeyboard] 不同，拦截发生在原生 `Activity.dispatchKeyEvent`
/// 层，不受 Flutter 生命周期过渡事件漏发的影响，后台/前台来回切换后依然可靠。
class VolumeKeyService {
  static final VolumeKeyService instance = VolumeKeyService();

  static const _channel = AppMethodChannel('fqapp/volume-key');

  /// 原生拦截到音量键时回调，参数为翻页方向。由阅读页注册。
  void Function(int direction)? _onVolumeKey;

  VolumeKeyService() {
    _channel.setMethodCallHandler((call) {
      if (call.method == 'volumeKey') {
        final direction = call.arguments as int? ?? 0;
        if (direction != 0) _onVolumeKey?.call(direction);
      }
      return Future<void>.value();
    });
  }

  /// 注册/注销音量键回调。传 null 即注销。
  void setOnVolumeKey(void Function(int direction)? callback) {
    _onVolumeKey = callback;
  }

  /// 通知原生是否拦截音量键。
  Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', enabled);
    } on MissingPluginException {
      // 插件未注册（如桌面调试）时忽略。
    } on PlatformException {
      // 忽略通道异常，不影响阅读。
    }
  }
}
