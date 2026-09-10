import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class ReaderDeviceStatus {
  final DateTime time;
  final int? battery;
  final bool charging;
  final double? systemBrightness;

  const ReaderDeviceStatus({
    required this.time,
    this.battery,
    this.charging = false,
    this.systemBrightness,
  });

  factory ReaderDeviceStatus.fromMap(Map<dynamic, dynamic> value) {
    final battery = value['battery'];
    final brightness = value['systemBrightness'];
    final timestamp = value['timestamp'];
    return ReaderDeviceStatus(
      time: timestamp is int
          ? DateTime.fromMillisecondsSinceEpoch(timestamp)
          : DateTime.now(),
      battery: battery is int && battery >= 0 && battery <= 100
          ? battery
          : null,
      charging: value['charging'] == true,
      systemBrightness: brightness is num && brightness.isFinite
          ? brightness.toDouble().clamp(0.02, 1)
          : null,
    );
  }
}

class ReaderFont {
  final String path;
  final String name;

  const ReaderFont({required this.path, required this.name});
}

// Note: 阅读亮度按会话恢复，系统广播更新时间、电量；见
// .agents/notes/implemented/feature/2026-09-10-reader-interface.md
class ReaderDevice {
  static const _channel = MethodChannel('fqapp/reader');
  static const _events = EventChannel('fqapp/reader/events');
  static final _eventStream = _events.receiveBroadcastStream();
  static int _nextSession = 0;
  final String _session =
      '${DateTime.now().microsecondsSinceEpoch}-${_nextSession++}';
  bool _closed = false;

  Stream<ReaderDeviceStatus> get changes => _eventStream
      .where((event) => event is Map && event['session'] == _session)
      .map((event) => ReaderDeviceStatus.fromMap(event as Map));

  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async {
    if (_closed) return null;
    try {
      final value = await _channel.invokeMapMethod<dynamic, dynamic>('start', {
        'session': _session,
        'brightness': followSystem ? -1.0 : brightness,
      });
      return _closed || value == null
          ? null
          : ReaderDeviceStatus.fromMap(value);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> setBrightness({
    required bool followSystem,
    required double brightness,
  }) async {
    if (_closed) return false;
    try {
      return await _channel.invokeMethod<bool>('setBrightness', {
            'session': _session,
            'brightness': followSystem ? -1.0 : brightness,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> suspend() => _finish('suspend');

  Future<void> close() {
    _closed = true;
    return _finish('stop');
  }

  Future<void> _finish(String method) async {
    try {
      await _channel.invokeMethod<void>(method, {'session': _session});
    } on MissingPluginException {
      // Reading remains available on platforms without the Android bridge.
    } on PlatformException {
      // Activity/engine detachment also restores the native window.
    }
  }

  Future<ReaderFont?> pickFont() async {
    final value = await _channel.invokeMapMethod<String, dynamic>('pickFont');
    if (value == null || _closed) return null;
    final path = value['path'];
    final name = value['name'];
    if (path is! String || path.isEmpty || name is! String) return null;
    return ReaderFont(path: path, name: name);
  }
}

/// Each imported file has a content-addressed path, so loaded families can be
/// reused across chapters and subsequent visits to the reader.
class ReaderFonts {
  static final Map<String, Future<String>> _families = {};
  static int _nextFamily = 0;

  static Future<String?> load(String path) async {
    if (path.isEmpty) return null;
    final pending = _families[path];
    if (pending != null) return pending;
    final request = _load(path);
    _families[path] = request;
    try {
      return await request;
    } catch (_) {
      _families.remove(path);
      rethrow;
    }
  }

  static Future<String> _load(String path) async {
    final file = File(path);
    final length = await file.length();
    if (length < 12 || length > 32 * 1024 * 1024) {
      throw const FormatException('字体文件大小不受支持');
    }
    final family = 'ReaderImported${_nextFamily++}';
    final bytes = await file.readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    return family;
  }
}
