import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ai_client.dart';

/// Holds an Android `dataSync` foreground service while AI HTTP calls run.
///
/// The service is what keeps the process and network alive after the screen
/// turns off. It is deliberately fail-closed: when it cannot start, the caller
/// must not send a request that Android would freeze halfway through.
class AiRequestForeground {
  const AiRequestForeground._();

  static const _channel = MethodChannel('fqapp/ai_request');

  /// Returns only after Android has actually entered the foreground state.
  ///
  /// Non-Android platforms are a no-op; iOS/desktop keep their existing
  /// foreground-only behaviour.
  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    try {
      final result = await _channel.invokeMethod<String>('acquire');
      if (result != 'ok') {
        throw AiNetworkException('FOREGROUND_UNAVAILABLE', '无法保持后台连接，已取消本次请求');
      }
    } on AiNetworkException {
      rethrow;
    } on PlatformException catch (error) {
      throw AiNetworkException(error.code, error.message ?? '无法启动 AI 前台服务');
    } on MissingPluginException {
      throw const AiNetworkException(
        'FOREGROUND_UNAVAILABLE',
        '当前安装包缺少 AI 前台服务',
      );
    } catch (error) {
      throw AiNetworkException('FOREGROUND_UNAVAILABLE', '$error');
    }
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('release');
    } catch (error) {
      debugPrint('[AI] foreground release failed: $error');
    }
  }
}
