import 'dart:async';
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
  static bool _handlerInstalled = false;
  static final _aborts = <Completer<void>>{};

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'serviceStopped') {
        _abortAll();
      }
      return null;
    });
  }

  static void _abortAll() {
    final aborts = _aborts.toList(growable: false);
    _aborts.clear();
    for (final abort in aborts) {
      if (!abort.isCompleted) abort.complete();
    }
  }

  /// Returns only after Android has actually entered the foreground state.
  ///
  /// Non-Android platforms are a no-op; iOS/desktop keep their existing
  /// foreground-only behaviour.
  static Future<AiRequestLease> acquire() async {
    if (!Platform.isAndroid) return const AiRequestLease._noop();
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
    _installHandler();
    final abort = Completer<void>();
    _aborts.add(abort);
    return AiRequestLease._(abort);
  }

  static Future<void> _release(AiRequestLease lease) async {
    final abort = lease._abort;
    if (abort != null) _aborts.remove(abort);
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('release');
    } catch (error) {
      debugPrint('[AI] foreground release failed: $error');
    }
  }
}

/// One foreground-service reference. Completing [abortTrigger] makes the
/// underlying HTTP request stop instead of continuing to generate after the
/// user stopped the task or Android timed the service out.
class AiRequestLease {
  const AiRequestLease._noop() : _abort = null;
  const AiRequestLease._(Completer<void> abort) : _abort = abort;

  final Completer<void>? _abort;

  Future<void>? get abortTrigger => _abort?.future;

  Future<void> release() => AiRequestForeground._release(this);
}
