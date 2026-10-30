import 'dart:async';

/// Rate-limits a page's background refresh sweep.
///
/// The library page re-checks chapter counts whenever it becomes visible, when
/// the app resumes, and on pull-to-refresh. Without a floor every tab switch
/// and route return re-ran the whole sweep even though nothing could have
/// changed. Concurrent callers share the run in flight; [force] bypasses the
/// interval, which is what pull-to-refresh uses.
class UpdateCheckGate {
  UpdateCheckGate({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  DateTime? _lastStarted;
  Future<void>? _inFlight;

  Future<void> run(
    Future<void> Function() check, {
    required Duration interval,
    bool force = false,
  }) {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final last = _lastStarted;
    if (!force && last != null && _now().difference(last) < interval) {
      return Future<void>.value();
    }
    _lastStarted = _now();
    return _inFlight = check().whenComplete(() => _inFlight = null);
  }
}
