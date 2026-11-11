import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_platform.dart';
import 'platform_channel.dart';
import 'dart:async';
import 'app_log.dart';

bool get isLinuxDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

/// Linux media uses the shared desktop player; other channels remain explicit.
class LinuxPlatform with WindowListener {
  static final _instance = LinuxPlatform();
  static Future<void> Function()? beforeClose;
  static Future<void>? localDataInitialization;
  bool _closing = false;
  StreamSubscription<dynamic>? _sessionEvents;

  static Future<void> install() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(_instance);
    await windowManager.setPreventClose(true);
    PlatformChannels.events = (name) {
      if (name == 'fqapp/native_player/events' ||
          name == 'fqapp/reader/events') {
        return DesktopPlatform.instance.events(name);
      }
      if (name == 'fqapp/system_tts_events' ||
          name == 'fqapp/desktop_session_events') {
        return EventChannel(name).receiveBroadcastStream();
      }
      return const Stream.empty();
    };
    const MethodChannel('fqapp/native_player').setMethodCallHandler(
      (call) => PlatformChannels.notify(
        'fqapp/native_player',
        call.method,
        call.arguments,
      ),
    );
    await _instance._sessionEvents?.cancel();
    _instance._sessionEvents =
        const EventChannel(
          'fqapp/desktop_session_events',
        ).receiveBroadcastStream().listen(
          DesktopSystemSession.instance.accept,
          onError: (Object error) =>
              AppLog.w('session', 'Linux session unavailable: $error'),
        );
    try {
      final caps = await const MethodChannel(
        'fqapp/desktop_session',
      ).invokeMapMethod<String, dynamic>('capabilities');
      if (caps?['locked'] is bool) {
        DesktopSystemSession.instance.accept({
          'type': 'locked',
          'value': caps!['locked'],
        });
      }
      AppLog.w('session', 'Lock reliability unverified; subscriptions: $caps');
    } on PlatformException catch (error) {
      AppLog.w('session', 'Session unavailable: ${error.code}');
    } on MissingPluginException {
      AppLog.w('session', 'Native session bridge missing');
    }
    PlatformChannels.invoke = (channel, method, arguments) async {
      if (channel == 'fqapp/system_tts' ||
          (channel == 'fqapp/native_player' &&
              (method == 'startListenForeground' ||
                  method == 'stopListenForeground'))) {
        return MethodChannel(channel).invokeMethod<dynamic>(method, arguments);
      }
      if (channel == 'fqapp/native_player' || channel == 'fqapp/reader') {
        return DesktopPlatform.instance.invoke(channel, method, arguments);
      }
      if (channel == 'fqapp/local_books' && method == 'pickBookFile') {
        return DesktopPlatform.instance.pickBook();
      }
      throw PlatformException(
        code: 'unsupported_platform',
        message: 'Linux 实验版暂不支持此平台功能',
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
      await DesktopPlatform.instance.disposeMedia();
      await const MethodChannel(
        'fqapp/system_tts',
      ).invokeMethod<void>('shutdown');
      await const MethodChannel(
        'fqapp/native_player',
      ).invokeMethod<void>('stopListenForeground');
      await const MethodChannel(
        'fqapp/desktop_session',
      ).invokeMethod<void>('setKeepScreenOn', {'on': false});
      await _sessionEvents?.cancel();
      _sessionEvents = null;
      await windowManager.destroy();
    } catch (_) {
      _closing = false;
      rethrow;
    }
  }
}
