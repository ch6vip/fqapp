import 'dart:async';
import 'package:flutter/services.dart';

/// In-process Windows adapters retain the existing Android channel contracts.
/// Without an installed adapter, real channels (including test mocks) are used.
class PlatformChannels {
  static Future<dynamic> Function(String, String, dynamic)? invoke;
  static Stream<dynamic> Function(String)? events;
  static final callbacks = <String, Future<dynamic> Function(MethodCall)>{};
  static Future<dynamic> notify(
    String channel,
    String method, [
    dynamic args,
  ]) async => callbacks[channel]?.call(MethodCall(method, args));
}

class AppMethodChannel {
  const AppMethodChannel(this.name);
  final String name;
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final handler = PlatformChannels.invoke;
    if (handler == null) {
      return MethodChannel(name).invokeMethod<T>(method, arguments);
    }
    return await handler(name, method, arguments) as T?;
  }

  Future<Map<K, V>?> invokeMapMethod<K, V>(
    String method, [
    dynamic args,
  ]) async {
    final result = await invokeMethod<dynamic>(method, args);
    return result == null ? null : (result as Map).cast<K, V>();
  }

  Future<void> setMethodCallHandler(
    Future<dynamic> Function(MethodCall)? handler,
  ) async {
    if (handler == null) {
      PlatformChannels.callbacks.remove(name);
    } else {
      PlatformChannels.callbacks[name] = handler;
    }
    if (PlatformChannels.invoke == null) {
      MethodChannel(name).setMethodCallHandler(handler);
    }
  }
}

class AppEventChannel {
  const AppEventChannel(this.name);
  final String name;
  Stream<dynamic> receiveBroadcastStream([dynamic args]) =>
      PlatformChannels.events?.call(name) ??
      EventChannel(name).receiveBroadcastStream(args);
}
