import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// Contains timings and local episode numbers, never URLs, keys or API bodies.
class PlayerLoadSample {
  final int attempt;
  final int episode;
  final String trigger;
  final String outcome;
  final String source;
  final Map<String, int> stagesMs;
  final int totalMs;
  final int backgroundMs;
  final int? firstFrameMs;
  final int? playToFirstFrameMs;

  PlayerLoadSample({
    required this.attempt,
    required this.episode,
    required this.trigger,
    required this.outcome,
    required this.source,
    required Map<String, int> stagesMs,
    required this.totalMs,
    required this.backgroundMs,
    required this.firstFrameMs,
    required this.playToFirstFrameMs,
  }) : stagesMs = Map.unmodifiable(stagesMs);

  Map<String, Object?> toJson() => {
    'attempt': attempt,
    'episode': episode,
    'trigger': trigger,
    'outcome': outcome,
    'source': source,
    'stagesMs': stagesMs,
    'totalMs': totalMs,
    'backgroundMs': backgroundMs,
    'firstFrameMs': firstFrameMs,
    'playToFirstFrameMs': playToFirstFrameMs,
  };
}

class PlayerLoadDiagnostics {
  final Duration Function() _now;
  final ValueChanged<PlayerLoadSample> _report;

  PlayerLoadDiagnostics({
    Duration Function()? now,
    ValueChanged<PlayerLoadSample>? report,
  }) : _now = now ?? _monotonicClock(),
       _report = report ?? _log;

  PlayerLoadTrace begin({
    required int attempt,
    required int episode,
    required String trigger,
    required bool appActive,
  }) => PlayerLoadTrace._(this, attempt, episode, trigger, appActive);

  static void _log(PlayerLoadSample sample) {
    // 结构化一条进应用日志（设置 → 服务 → 日志 可读、可导出）；运转台仍走
    // debugPrint 保留 adb logcat 观感。日志页因此会同时看到紧凑行与完整 JSON。
    AppLog.d(
      'player-load',
      'episode=${sample.episode} trigger=${sample.trigger} '
      'outcome=${sample.outcome} source=${sample.source} '
      'total=${sample.totalMs}ms firstFrame=${sample.firstFrameMs ?? '-'}ms',
    );
    if (!kReleaseMode) {
      debugPrint('[PlayerLoad] ${jsonEncode(sample.toJson())}');
    }
  }
}

class PlayerLoadTrace {
  final PlayerLoadDiagnostics _diagnostics;
  final int attempt;
  final int episode;
  final String trigger;
  final Duration _started;
  final _stages = <String, int>{};
  Duration _stageStarted = Duration.zero;
  String _stage = 'address';
  String source = 'network';
  Duration? _playRequested;
  Duration? _firstFrame;
  Duration? _backgroundStarted;
  Duration _background = Duration.zero;
  bool _finished = false;

  PlayerLoadTrace._(
    this._diagnostics,
    this.attempt,
    this.episode,
    this.trigger,
    bool appActive,
  ) : _started = _diagnostics._now() {
    if (!appActive) _backgroundStarted = Duration.zero;
  }

  Duration get _elapsed => _diagnostics._now() - _started;

  void stage(String name) {
    if (_finished) return;
    final elapsed = _elapsed;
    _stages[_stage] = (elapsed - _stageStarted).inMilliseconds;
    _stageStarted = elapsed;
    _stage = name;
  }

  void playRequested() {
    if (_finished || _playRequested != null) return;
    _playRequested = _elapsed;
    stage('firstFrame');
  }

  void firstFrame() {
    if (!_finished) _firstFrame ??= _elapsed;
  }

  void setAppActive(bool active) {
    if (_finished) return;
    if (active) {
      if (_backgroundStarted case final started?) {
        _background += _elapsed - started;
        _backgroundStarted = null;
      }
    } else {
      _backgroundStarted ??= _elapsed;
    }
  }

  void finish(String outcome) {
    if (_finished) return;
    final elapsed = _elapsed;
    _stages[_stage] = (elapsed - _stageStarted).inMilliseconds;
    setAppActive(true);
    _finished = true;
    final frame = _firstFrame;
    final play = _playRequested;
    final sample = PlayerLoadSample(
      attempt: attempt,
      episode: episode,
      trigger: trigger,
      outcome: outcome,
      source: source,
      stagesMs: _stages,
      totalMs: elapsed.inMilliseconds,
      backgroundMs: _background.inMilliseconds,
      firstFrameMs: frame?.inMilliseconds,
      playToFirstFrameMs: frame != null && play != null && frame >= play
          ? (frame - play).inMilliseconds
          : null,
    );
    // Diagnostics must never turn a successful load into a playback error.
    try {
      _diagnostics._report(sample);
    } catch (_) {}
  }
}

Duration Function() _monotonicClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}
