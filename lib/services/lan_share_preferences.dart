import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted "share on the local network" switch for the local API.
///
/// Off by default. Turning it on widens the listener from `127.0.0.1` to every
/// interface, so any device on the same network can call the read routes. The
/// switch is persisted because the backend core binds its listener at startup,
/// and a user who turned sharing on expects it to survive a restart.
class LanSharePreferences {
  LanSharePreferences._();

  static final LanSharePreferences instance = LanSharePreferences._();

  static const key = 'api_lan_share_enabled';

  /// Off until [load] reads otherwise: exposing the API to the network is
  /// never the silent default.
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      enabled.value = sp.getBool(key) ?? false;
    } catch (_) {
      // A broken optional preference reads as its default.
    }
  }

  /// Forgets the loaded state so the next [load] re-reads SharedPreferences.
  ///
  /// Only for tests: `_loaded` is a process-wide one-shot guard, so a value
  /// swapped in by `setMockInitialValues` is not picked up otherwise.
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    enabled.value = false;
  }

  /// Writes the new value and persists it; a failed write keeps the in-session
  /// value so the switch still reflects what the user chose.
  Future<void> setEnabled(bool value) async {
    enabled.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(key, value);
    } catch (_) {
      // The in-session value still applies; only persistence failed.
    }
  }
}
