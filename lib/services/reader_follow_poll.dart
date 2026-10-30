import 'dart:async';

/// The reader's 10Hz listening-follow poll, started only while it is useful.
///
/// The timer used to be created in `initState` and kept waking the UI isolate
/// ten times a second for the page's whole lifetime — with no listening
/// session at all, or while the app was in the background. Callers re-run
/// [sync] on session and app-lifecycle changes; the timer exists only while
/// [needed] says there is work to do.
///
/// Polling instead of the session's 1Hz notifications is deliberate: those fire
/// at most once a second and only on structural changes, while following needs
/// the playback position ten times a second to address the spoken character.
class ReaderFollowPoll {
  ReaderFollowPoll(this.tick, this.needed);

  static const interval = Duration(milliseconds: 100);

  /// Follow ticks per periodic progress save (10Hz ⇒ 2s). While following, the
  /// page is jumped programmatically on every tick, so the scroll controller's
  /// 500ms save debounce never fires; the poll supplies its own cadence.
  static const saveEvery = 20;

  final void Function() tick;
  final bool Function() needed;

  Timer? _timer;
  int _ticks = 0;

  /// Starts or stops the timer to match [needed]. Cheap enough to call on every
  /// structural change.
  void sync() {
    final wanted = needed();
    if (wanted == (_timer != null)) return;
    if (wanted) {
      _timer = Timer.periodic(interval, (_) => tick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Counts one tick that actually followed; true once every [saveEvery] ticks.
  bool saveDue() {
    if (++_ticks < saveEvery) return false;
    _ticks = 0;
    return true;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
