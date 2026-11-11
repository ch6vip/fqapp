import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_platform.dart';
import 'platform_channel.dart';

bool get isLinuxDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

/// First-batch adapters only. Never forward unsupported calls to Android.
class LinuxPlatform with WindowListener {
  static final _instance = LinuxPlatform();
  static Future<void> Function()? beforeClose;
  static Future<void>? localDataInitialization;
  bool _closing = false;

  static Future<void> install() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(_instance);
    await windowManager.setPreventClose(true);
    PlatformChannels.events = (_) => const Stream.empty();
    PlatformChannels.invoke = (channel, method, arguments) async {
      if (channel == 'fqapp/local_books' && method == 'pickBookFile') {
        return DesktopPlatform.instance.pickBook();
      }
      throw PlatformException(
        code: 'unsupported_platform',
        message: 'Linux 实验版暂不支持此功能（媒体、系统朗读及桌面集成将在后续提供）',
      );
    };
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      try {
        await localDataInitialization;
      } catch (_) {
        // A failed bootstrap still permits closing the error screen.
      }
      await beforeClose?.call();
      await windowManager.destroy();
    } catch (_) {
      _closing = false;
      rethrow;
    }
  }
}
