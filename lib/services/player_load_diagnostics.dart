import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_log.dart';

const _allowedStages = <String>{
  'address',
  'releaseWait',
  'history',
  'pagingBeforeCreate',
  'create',
  'initialize',
  'pagingBeforePlay',
  'autoplayWait',
  'firstFrame',
  'other',
};
const _allowedTriggers = <String>{'initial', 'switch', 'retry'};
const _allowedOutcomes = <String>{
  'firstFrame',
  'error',
  'disposed',
  'superseded',
};
const _allowedSources = <String>{
  'network',
  'cacheHit',
  'pending',
  'prefetchHit',
  'prefetchPending',
  'offline',
};

String _safeLabel(String value, Set<String> allowed) =>
    allowed.contains(value) ? value : 'other';

int? _safeErrorCode(int? value) =>
    value != null && value >= 1 && value <= 9999 ? value : null;

int? _safeHttpStatus(int? value) =>
    value != null && value >= 100 && value <= 599 ? value : null;

/// Contains only allow-listed labels, timings, episode index and numeric error
/// metadata. Raw exceptions, URLs, keys, tokens and response bodies are never
/// copied into this sample or its serialized log representation.
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
  final String? failureStage;
  final int? errorCode;
  final int? httpStatusCode;

  PlayerLoadSample({
    required this.attempt,
    required this.episode,
    required String trigger,
    required String outcome,
    required String source,
    required Map<String, int> stagesMs,
    required this.totalMs,
    required this.backgroundMs,
    required this.firstFrameMs,
    required this.playToFirstFrameMs,
    required String? failureStage,
    required int? errorCode,
    required int? httpStatusCode,
  }) : trigger = _safeLabel(trigger, _allowedTriggers),
       outcome = _safeLabel(outcome, _allowedOutcomes),
       source = _safeLabel(source, _allowedSources),
       stagesMs = Map.unmodifiable({
         for (final entry in stagesMs.entries)
           if (_allowedStages.contains(entry.key) && entry.value >= 0)
             entry.key: entry.value,
       }),
       failureStage = failureStage == null
           ? null
           : _safeLabel(failureStage, _allowedStages),
       errorCode = _safeErrorCode(errorCode),
       httpStatusCode = _safeHttpStatus(httpStatusCode);

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
    'failureStage': failureStage,
    'errorCode': errorCode,
    'httpStatusCode': httpStatusCode,
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
    // Release logs include every phase and numeric error field. This JSON is
    // assembled only from allow-listed labels and primitive diagnostic values.
    final json = jsonEncode(sample.toJson());
    AppLog.d('player-load', json);
    if (!kReleaseMode) debugPrint('[PlayerLoad] $json');
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
  String? _failureStage;
  int? _errorCode;
  int? _httpStatusCode;
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
    _stage = _allowedStages.contains(name) ? name : 'other';
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

  /// Ends an unsuccessful attempt with a safe phase label and numeric codes.
  /// Error strings are intentionally not accepted by this API.
  void fail({int? errorCode, int? httpStatusCode}) {
    if (_finished) return;
    _failureStage = _stage;
    _errorCode = errorCode;
    _httpStatusCode = httpStatusCode;
    finish('error');
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
      failureStage: _failureStage,
      errorCode: _errorCode,
      httpStatusCode: _httpStatusCode,
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
