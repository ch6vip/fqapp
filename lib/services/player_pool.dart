// Note: 为什么短剧 feed 需要一个播放器池、池与路由级播放器的边界 — 见
// .agents/notes/implemented/feature/2026-09-21-drama-player-pool.md

import 'dart:async';

import 'native_player.dart';



/// A paused player parked in the [PlayerPool] together with the session state
/// needed to resume it without rebuilding anything.
class ParkedPlayer {
  ParkedPlayer(this.player, {this.payload});

  final NativePlayer player;

  /// Opaque session state (the 短剧 session stores its episode list, the
  /// playing index and the tab it was requested with). The pool never reads it.
  final Object? payload;
}

/// The 短剧 feed's shared player pool, mirroring the official
/// `ShortPlayerSharePool` (`gq3/b.java`, log tag `ShortPlayerSharePool`).
///
/// The official feed does not release a player when the viewer swipes away: it
/// pauses it and keeps it under the **video id**
/// (`jq3/x.java:4681-4690 cacheSharePlayerAndUnBindCurPlayer` →
/// `gq3.b.a.g(vid, wrapper)`), then re-uses it when that id comes back
/// (`gq3/b.java:101 f(playerKey)`; the pre-check is
/// `SeriesBookMallTabFragment.java:916`). Swiping back therefore resumes the
/// same decoder instead of rebuilding one.
///
/// Our key is the drama's content id (`seriesId ?? id`), which is this app's
/// equivalent of the official `vid` — one feed card is one series, and the
/// session always resumes it on the same episode.
///
/// Capacity is bounded, unlike the official map: every parked player holds a
/// decoder, so the pool keeps a fixed window and disposes the least recently
/// parked entry beyond it. The official client frees the whole map when it
/// leaves the feed (`ShortSeriesImpl.java:165 sharePlayerPoolRelease` →
/// `gq3/b.java:47 h()`), which is what [releaseAll] does here.
class PlayerPool {
  PlayerPool({this.capacity = 3});

  /// How many paused players may stay alive at once.
  final int capacity;

  /// Insertion-ordered, so `keys.first` is the least recently parked entry.
  final Map<String, ParkedPlayer> _entries = <String, ParkedPlayer>{};
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;

  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  /// Parked keys, least recently parked first. For tests and diagnostics.
  List<String> get keys => List<String>.unmodifiable(_entries.keys);

  /// The parked entry for [key] without removing it
  /// (`gq3/b.java:63 b(playerKey)`, the "is it already in the pool" check).
  ParkedPlayer? peek(String key) => _entries[key];

  /// Take [key]'s entry out of the pool; the caller owns the player again
  /// (`gq3/b.java:101 f(playerKey)`). Returns null when nothing was parked.
  ParkedPlayer? acquire(String key) => _entries.remove(key);

  /// Keep [player] under [key]. A previously parked player for the same key (a
  /// restart, not a reuse) and anything beyond [capacity] are disposed.
  void park(String key, NativePlayer player, {Object? payload}) {
    final entry = ParkedPlayer(player, payload: payload);
    if (_disposed) {
      _queueDispose(player);
      return;
    }
    final replaced = _entries.remove(key);
    if (replaced != null && !identical(replaced.player, player)) {
      _queueDispose(replaced.player);
    }
    _entries[key] = entry;
    while (_entries.length > capacity) {
      final oldest = _entries.keys.first;
      final evicted = _entries.remove(oldest);
      if (evicted != null) _queueDispose(evicted.player);
    }
  }

  /// Drop and dispose every parked player
  /// (`gq3/b.java:47 h()` — `pause()` then `release()` on each).
  Future<void> releaseAll() async {
    final players = [
      for (final entry in _entries.values) entry.player,
    ];
    _entries.clear();
    for (final player in players) {
      _queueDispose(player);
    }
    await _pending;
  }

  Future<void> dispose() async {
    _disposed = true;
    await releaseAll();
  }

  /// Disposals are serialised: two native players must never be torn down
  /// concurrently, and the caller must not wait for one to finish a swipe.
  void _queueDispose(NativePlayer player) {
    _pending = _pending.then((_) => _disposeQuietly(player));
  }

  static Future<void> _disposeQuietly(NativePlayer player) async {
    try {
      await player.pause();
    } catch (_) {
      // A player that refuses to pause is on its way out anyway.
    }
    try {
      await player.dispose();
    } catch (_) {
      // Teardown is best effort; the entry is already out of the pool.
    }
  }
}
