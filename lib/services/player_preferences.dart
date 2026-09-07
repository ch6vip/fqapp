import 'package:shared_preferences/shared_preferences.dart';

class PlayerPreferences {
  static const _playbackRateKey = 'player_playback_rate';
  static const _autoAdvanceKey = 'player_auto_advance';
  static Future<void>? _autoAdvanceWrites;
  static const playbackRates = <double>[0.75, 1, 1.25, 1.5, 2];

  static Future<double> loadPlaybackRate() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.get(_playbackRateKey);
    return normalizePlaybackRate(saved is num ? saved.toDouble() : 1);
  }

  static Future<void> savePlaybackRate(double rate) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(_playbackRateKey, normalizePlaybackRate(rate));
  }

  static Future<bool> loadAutoAdvance() async {
    final pending = _autoAdvanceWrites;
    if (pending != null) await pending;
    final preferences = await SharedPreferences.getInstance();
    return preferences.get(_autoAdvanceKey) is bool
        ? preferences.getBool(_autoAdvanceKey)!
        : true;
  }

  static Future<void> saveAutoAdvance(bool enabled) {
    // Share the queue across pages so immediate exit/reentry cannot reorder
    // a previous page's writes after the user's newer choice.
    final write = (_autoAdvanceWrites ?? Future<void>.value()).then((_) async {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setBool(_autoAdvanceKey, enabled)) {
        throw StateError('Could not save automatic episode playback');
      }
    });
    late final Future<void> settled;
    settled = write.catchError((Object _) {}).whenComplete(() {
      if (identical(_autoAdvanceWrites, settled)) _autoAdvanceWrites = null;
    });
    _autoAdvanceWrites = settled;
    return write;
  }
}

double normalizePlaybackRate(double value) {
  if (!value.isFinite || value <= 0) return 1;
  return PlayerPreferences.playbackRates.reduce(
    (best, candidate) =>
        (candidate - value).abs() < (best - value).abs() ? candidate : best,
  );
}
