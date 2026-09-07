import 'package:flutter/services.dart';

enum PlayerAdjustment { brightness, volume }

class PlayerDeviceLevels {
  final double brightness;
  final double volume;

  const PlayerDeviceLevels(this.brightness, this.volume);

  factory PlayerDeviceLevels.fromMap(Map<Object?, Object?> values) =>
      PlayerDeviceLevels(
        (values['brightness'] as num).toDouble().clamp(.05, 1.0),
        (values['volume'] as num).toDouble().clamp(0.0, 1.0),
      );
}

/// A window-scoped adjustment session, independent of the current decoder.
/// Commands are ordered so a late read/write cannot undo brightness cleanup.
class PlayerDeviceControls {
  static const _channel = MethodChannel('fqapp/native_player');
  static const _timeout = Duration(seconds: 3);
  static int _nextSession = 0;
  int? _session;
  int _generation = 0;
  Future<void> _operations = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final operation = _operations.then((_) => action());
    _operations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<PlayerDeviceLevels?> read() {
    final generation = _generation;
    return _enqueue(() async {
      if (generation != _generation) return null;
      final starting = _session == null;
      final session = _session ??= ++_nextSession;
      final values = await _channel
          .invokeMapMethod<Object?, Object?>(
            starting ? 'beginDeviceControls' : 'readDeviceControls',
            {'session': session},
          )
          .timeout(_timeout);
      if (generation != _generation) return null;
      if (values == null) throw StateError('Device controls unavailable');
      return PlayerDeviceLevels.fromMap(values);
    });
  }

  Future<double?> setLevel(PlayerAdjustment adjustment, double value) {
    final generation = _generation;
    return _enqueue(() async {
      final session = _session;
      if (generation != _generation || session == null) return null;
      return _channel
          .invokeMethod<double>(
            adjustment == PlayerAdjustment.brightness
                ? 'setScreenBrightness'
                : 'setMediaVolume',
            {'session': session, 'value': value},
          )
          .timeout(_timeout);
    });
  }

  Future<void> reset() {
    ++_generation;
    final session = _session;
    _session = null;
    return _enqueue(() async {
      if (session != null) {
        await _channel
            .invokeMethod<void>('endDeviceControls', {'session': session})
            .timeout(_timeout);
      }
    });
  }
}
