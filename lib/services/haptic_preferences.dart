import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One app-wide choice for both UI styles; existing installations stay enabled.
class HapticPreferences extends ValueNotifier<bool> {
  HapticPreferences._() : super(true);

  static final instance = HapticPreferences._();
  static const storageKey = 'haptics_enabled';
  static const _channel = MethodChannel('fqapp/haptics');

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();
  bool _loaded = false;
  int _revision = 0;

  Future<void> load() {
    if (_loaded || !supported) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (revision == _revision && revision == 0) {
        value = prefs.get(storageKey) != false;
        if (!await _applyPlatform(value)) {
          throw StateError('Could not apply the Android haptic preference');
        }
      }
      _loaded = true;
    } finally {
      _loading = null;
    }
  }

  /// Apply before awaiting storage. Serialized writes keep rapid taps ordered.
  Future<bool> setEnabled(bool enabled) async {
    ++_revision;
    value = enabled;
    final applied = _applyPlatform(enabled);
    final saved = _writes.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        return await prefs.setBool(storageKey, enabled);
      } catch (_) {
        return false;
      }
    });
    _writes = saved.then<void>((_) {});
    final results = await Future.wait([applied, saved]);
    return results.every((ok) => ok);
  }

  Future<bool> _applyPlatform(bool enabled) async {
    if (!supported) return true;
    try {
      // Android's window gate also covers implicit Material long-press haptics.
      // A silent platform channel must not keep optional startup work pending.
      return await _channel
              .invokeMethod<bool>('setEnabled', enabled)
              .timeout(const Duration(seconds: 2), onTimeout: () => false) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
