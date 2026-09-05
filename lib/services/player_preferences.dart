import 'package:shared_preferences/shared_preferences.dart';

class PlayerPreferences {
  static const _playbackRateKey = 'player_playback_rate';
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
}

double normalizePlaybackRate(double value) {
  if (!value.isFinite || value <= 0) return 1;
  return PlayerPreferences.playbackRates.reduce(
    (best, candidate) =>
        (candidate - value).abs() < (best - value).abs() ? candidate : best,
  );
}
