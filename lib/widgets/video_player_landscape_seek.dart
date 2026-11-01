part of 'video_player_chrome.dart';

/// Keep drag previews and native progress live without rebuilding the controls.
extension _LandscapeSeekBar on _VideoPlayerChromeState {
  Widget _landscapeSeekBar() => ListenableBuilder(
    listenable: _timeline,
    builder: (context, _) => StorySeekBar(
      key: const ValueKey('landscape-seek'),
      value: _progressValue,
      enabled: widget.duration > Duration.zero,
      seeking: _seeking,
      onStart: _startSeek,
      onChanged: (value) => _seekValue.value = value,
      onEnd: (value) => unawaited(_finishSeek(value)),
      onCancel: _cancelSeek,
      trackWidth: 3,
      thumbRadius: 6,
      progressColor: const Color(0xFFFA6725),
      trackColor: const Color(0x47FFFFFF),
    ),
  );
}
