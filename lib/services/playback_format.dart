/// Playback time and rate formatting shared by the audio page and the video
/// chrome. Both players used to carry private copies that had already started
/// drifting; one formatter keeps `75:30` (minutes beyond an hour stay in the
/// minutes column) and the integer-rate trimming identical everywhere.
String formatPlaybackTime(Duration value) {
  final seconds = value.inSeconds.clamp(0, 0x7fffffff);
  final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// `1` instead of `1.0`, `1.25` kept as-is — matching the official rate menus.
String formatPlaybackRate(double rate) =>
    rate == rate.roundToDouble() ? rate.toInt().toString() : rate.toString();
