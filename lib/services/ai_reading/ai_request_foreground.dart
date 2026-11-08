import 'dart:async';

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
  static bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
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

  @visibleForTesting
  static void debugServiceStopped() => _abortAll();

  static void _abortAll() {
    final aborts = _aborts.toList(growable: false);
    _aborts.clear();
    for (final abort in aborts) {
      if (!abort.isCompleted) abort.complete();
    }
  }

  /// Asks Android 13+ for the notification permission once. The foreground
  /// service still works when this is denied; only the visible stop action
  /// disappears, so callers must not block a request on the result.
  static Future<bool> ensureNotificationPermission() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestNotifications') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('[AI] notification permission request failed: ${error.code}');
      return false;
    } catch (error) {
      debugPrint('[AI] notification permission request failed: $error');
      return false;
    }
  }

  /// Updates the visible foreground notification. Ignored on other platforms
  /// and when the native service is not running yet.
  static Future<void> updateNotification(String text) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('updateNotification', {'text': text});
    } catch (error) {
      debugPrint('[AI] notification update failed: $error');
    }
  }

  /// Returns only after Android has actually entered the foreground state.
  ///
  /// Non-Android platforms are a no-op; iOS/desktop keep their existing
  /// foreground-only behaviour.
  static Future<AiRequestLease> acquire() async {
    if (!_isAndroid) return const AiRequestLease._noop();
    _installHandler();
    final abort = Completer<void>();
    _aborts.add(abort);
    final String leaseId;
    try {
      final result = await _channel.invokeMethod<String>('acquire');
      if (result == null || result.isEmpty) {
        throw AiNetworkException('FOREGROUND_UNAVAILABLE', '无法保持后台连接，已取消本次请求');
      }
      leaseId = result;
    } on AiNetworkException {
      _aborts.remove(abort);
      rethrow;
    } on PlatformException catch (error) {
      _aborts.remove(abort);
      throw AiNetworkException(error.code, error.message ?? '无法启动 AI 前台服务');
    } on MissingPluginException {
      _aborts.remove(abort);
      throw const AiNetworkException(
        'FOREGROUND_UNAVAILABLE',
        '当前安装包缺少 AI 前台服务',
      );
    } catch (error) {
      _aborts.remove(abort);
      throw AiNetworkException('FOREGROUND_UNAVAILABLE', '$error');
    }
    if (abort.isCompleted) {
      try {
        await _channel.invokeMethod<void>('release', {'leaseId': leaseId});
      } catch (error) {
        debugPrint('[AI] foreground handshake release failed: $error');
      }
      throw const AiNetworkException('FOREGROUND_STOPPED', 'AI 前台服务在启动握手期间已停止');
    }
    return AiRequestLease._(leaseId, abort);
  }

  static Future<void> _release(AiRequestLease lease) async {
    final abort = lease._abort;
    if (abort != null) _aborts.remove(abort);
    final leaseId = lease._leaseId;
    if (!_isAndroid || leaseId == null) return;
    try {
      await _channel.invokeMethod<void>('release', {'leaseId': leaseId});
    } catch (error) {
      debugPrint('[AI] foreground release failed: $error');
    }
  }
}

/// One foreground-service reference. Completing [abortTrigger] makes the
/// underlying HTTP request stop instead of continuing to generate after the
/// user stopped the task or Android timed the service out.
class AiRequestLease {
  const AiRequestLease._noop() : _leaseId = null, _abort = null;
  const AiRequestLease._(String leaseId, Completer<void> abort)
    : _leaseId = leaseId,
      _abort = abort;

  final String? _leaseId;
  final Completer<void>? _abort;

  Future<void>? get abortTrigger => _abort?.future;

  Future<void> release() => AiRequestForeground._release(this);
}
