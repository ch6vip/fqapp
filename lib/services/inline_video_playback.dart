// Note: 短剧 tab 的内联播放会话、播放器池复用策略，以及有意省略的能力 —
// 见 .agents/notes/implemented/feature/2026-09-20-inline-drama-playback.md

import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import 'api_client.dart';
import 'drama_mute_preferences.dart';
import 'episode_source_cache.dart';
import 'library_store.dart';
import 'native_player.dart';
import 'player_history.dart';
import 'player_pool.dart';
import 'user_facing_error.dart';

/// The inline playback session of one 短剧 feed page.
///
/// A session owns at most one [NativePlayer] at a time and never outlives its
/// page: [activate] invalidates the in-flight generation, releases the previous
/// player and waits for that release before creating the next one, so two
/// ExoPlayer instances can never be alive together. A late `create` from a
/// superseded activation is disposed instead of being adopted.
///
/// Progress is saved when a player is stopped or released, using the same
/// fields as the full page player (`player_page.dart`). Deliberately *not*
/// implemented in this round: 累计阅读时长/统计、诊断日志、倍速、seek、自动连播、
/// 相邻剧地址预取 — the inline feed only starts, stops and remembers where the
/// viewer was.
class InlineVideoPlayback {
  InlineVideoPlayback({
    this.directoryLoader,
    this.contentLoader,
    this.playerFactory,
    EpisodeSourceCache? sources,
    this.historyStore,
    PlayerPool? pool,
  }) : pool = pool ?? PlayerPool() {
    // The address cache is page-local: it keeps {url,keyHex} for at most two
    // episodes with a two minute TTL and never downloads media bytes.
    _sources =
        sources ??
        EpisodeSourceCache(
          loader: (chapter) async =>
              EpisodeSource.fromResponse(await _content(chapter.itemId)),
        );
  }

  /// The page's shared player pool (`ShortPlayerSharePool`). A parked player is
  /// paused, not released, so swiping back resumes the same decoder
  /// (`gq3/b.java`, `jq3/x.java:4681-4690`).
  final PlayerPool pool;

  /// Test/tuning seams, mirroring the injectable seams of `PlayerPage`.
  final Future<List<List<Chapter>>> Function(String id, String tab)?
  directoryLoader;
  final Future<Map<String, dynamic>> Function(String itemId, String tab)?
  contentLoader;
  final NativePlayer Function()? playerFactory;
  final ReaderStore? historyStore;
  late final EpisodeSourceCache _sources;

  /// Texture of the current player, `null` while nothing is mounted.
  final ValueNotifier<int?> textureId = ValueNotifier<int?>(null);

  /// Whether the current player already produced a frame. `create` completing
  /// only means the texture and decoder were allocated.
  final ValueNotifier<bool> firstFrame = ValueNotifier<bool>(false);

  /// User-facing text of the last failure, `null` while the session is healthy.
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  /// Playback was requested and the current episode has not completed.
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);

  /// Id of the drama this session is currently targeting. Set synchronously at
  /// the start of [activate], cleared by [release].
  final ValueNotifier<String?> activeId = ValueNotifier<String?>(null);

  /// Quarter turns the texture still needs (native rotation correction).
  final ValueNotifier<int> rotation = ValueNotifier<int>(0);

  /// Video pixel size of the current episode, `Size.zero` until the decoder
  /// reports one. The feed lays the texture out with the same contain rule as
  /// the full page player, so a landscape drama is not squeezed into a 9:16
  /// box; `PlayerVideoLayout` turns an unknown (0×0) size into that fallback.

  /// Playback position and duration of the current episode, for the card's
  /// seek bar (`cjt.xml`, 16dp tall).
  final ValueNotifier<Duration> position = ValueNotifier<Duration>(
    Duration.zero,
  );
  final ValueNotifier<Duration> duration = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// Whether playback is muted.
  ///
  /// 官方信息流播放器的静音直接取会话态 `needMutePlay`（`tm3/b.java` 初始
  /// false；`holder/a.java:640 setIsMute(needMutePlay)`）——**出厂默认有声**，
  /// 只有用户开过「开启应用时默认静音」或在更多面板开「静音播放」才静音并
  /// 出现「取消静音」药丸（`mq3/c.java` + `bvf.xml`）。这里取同一默认，
  /// 冷启动静音由 [DramaMutePreferences] 决定（见 `_DramaPageState`）。
  final ValueNotifier<bool> muted = ValueNotifier<bool>(false);

  /// Playback rate. `PlayerVideoSpeedTipsView` shows `@string/ec6`=
  /// 「2倍速快进中」 while the viewer holds a long press (`cjx.xml`, 83dp tall),
  /// which is the gesture `VideoGestureDetectLayout.onLongPress` forwards.
  final ValueNotifier<double> rate = ValueNotifier<double>(1.0);

  /// Video pixel size of the current episode, `Size.zero` until the decoder
  /// reports one. The feed lays the texture out with the same contain rule as
  /// the full page player, so a landscape drama is not squeezed into a 9:16
  /// box; `PlayerVideoLayout` turns an unknown (0×0) size into that fallback.
  final ValueNotifier<Size> videoSize = ValueNotifier<Size>(Size.zero);

  bool _muted = false;
  bool _coldStartMuteApplied = false;
  double _rate = 1.0;

  /// The tab a directory/content request must use. Only one activation runs at
  /// a time, so a single field is enough for the shared address cache loader.
  String _tab = '短剧';

  final Map<String, List<Chapter>> _directories = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  Future<void> _releases = Future<void>.value();

  NativePlayer? _player;
  MediaItem? _active;
  List<Chapter> _episodes = const [];
  int? _activeIndex;
  int _generation = 0;
  bool _hasDisplayed = false;
  bool _wantsPlay = true;
  bool _disposed = false;
  bool _reusedFromPool = false;

  /// True while a player instance exists (playing or paused).
  bool get hasPlayer => _player != null;

  /// True while the current player is a decoder taken back out of [pool].
  ///
  /// A reused player already has its texture, its size and its position, so
  /// [activate] must not reset those notifiers or seek back to the start.
  bool get reusedFromPool => _reusedFromPool;

  PlayerHistory get _history =>
      PlayerHistory(historyStore ?? LibraryStore.instance);

  bool _current(int generation, [NativePlayer? player]) =>
      !_disposed &&
      generation == _generation &&
      (player == null || identical(player, _player));

  bool _playbackRequested(NativePlayer player) =>
      player.playing || (player.playWhenReady && !player.completed);

  Future<Map<String, dynamic>> _content(String itemId) {
    final loader = contentLoader;
    if (loader != null) return loader(itemId, _tab);
    return ApiClient.instance.content(itemId, tab: _tab, mode: 'stream');
  }

  /// The series directory, cached once per page session. A single-episode
  /// search result has no directory, so it falls back to its own item id.
  ///
  /// `tab` is a named parameter of the client, so it is passed by name: a tear
  /// off used positionally degrades to a `dynamic` call.
  Future<List<Chapter>> _episodesFor(
    String contentId,
    String tab,
    MediaItem series,
  ) async {
    final key = '$contentId|$tab';
    final cached = _directories[key];
    if (cached != null) return cached;
    final loader = directoryLoader;
    final volumes = loader != null
        ? await loader(contentId, tab)
        : await ApiClient.instance.directoryChapters(contentId, tab: tab);
    final List<List<Chapter>> resolved =
        volumes.isEmpty && series.episodeId != null
        ? [
            [
              Chapter(
                itemId: series.episodeId!,
                title: series.title,
                volumeName: '剧集',
              ),
            ],
          ]
        : volumes;
    final episodes = <Chapter>[
      for (final volume in resolved) ...volume,
    ];
    if (episodes.isNotEmpty) _directories[key] = episodes;
    return episodes;
  }

  /// Start [series] from its resume episode (or the first one).
  ///
  /// A drama that is still parked in [pool] is **reused**: its decoder, texture,
  /// video size and playback position all survive, so swiping back shows the
  /// paused frame immediately instead of rebuilding a player (official
  /// `gq3.b.a.f(playerKey)` / `jq3/x.java:1771`).
  ///
  /// Otherwise any earlier activation is invalidated first: its directory
  /// request, its `create` and its subscriptions can no longer touch this
  /// session, and the previous player is parked (not destroyed).
  Future<void> activate(MediaItem series) async {
    if (_disposed) return;
    final generation = ++_generation;
    final contentId = series.seriesId ?? series.id;
    final tab = series.kind == 'manju' ? '漫剧' : '短剧';
    // The drama being left still belongs to the old player, so its progress is
    // captured before the state below is replaced. Writes queue behind each
    // other per store, so the next read still sees this entry.
    final previous = _player;
    final previousId = _active == null ? null : _poolKey(_active!);
    if (previous != null) unawaited(_persistProgress());
    _tab = tab;
    _active = series;
    _hasDisplayed = false;
    _wantsPlay = true;
    _reusedFromPool = false;
    activeId.value = series.id;
    firstFrame.value = false;
    error.value = null;
    playing.value = false;
    // The previous player is parked rather than released when a new drama
    // takes over: that is what makes a swipe back instant. Its subscriptions
    // are dropped here so it stops driving this session's notifiers.
    _detachSubscriptions();
    _player = null;
    if (previous != null && previousId != null && previousId != contentId) {
      pool.park(previousId, previous);
    } else if (previous != null && previousId == contentId) {
      // Same drama re-activated (a retry): the old decoder is stale.
      unawaited(previous.dispose());
    }

    // Reuse path: the pool still holds this drama's paused decoder.
    final parked = pool.acquire(contentId);
    if (parked != null) {
      final player = parked.player;
      try {
        await player.pause();
      } catch (_) {
        // A parked player is already paused; a refusal is not fatal.
      }
      if (!_current(generation) || !player.isCreated) {
        // The entry went stale while the request was in flight.
        await player.dispose();
      } else {
        _player = player;
        _reusedFromPool = true;
        _subscribe(player, generation);
        textureId.value = player.textureId;
        _adoptVideoSize(player);
        rotation.value = player.videoRotationCorrection ~/ 90;
        position.value = player.position;
        duration.value = player.duration;
        if (player.firstFrameRendered) _onFirstFrame(player, generation);
        await _resumeReused(player, generation);
        return;
      }
    }

    // Restart the value notifiers now: either nothing was parked, or the parked
    // entry above was rejected.
    _activeIndex = null;
    rotation.value = 0;
    videoSize.value = Size.zero;
    // The progress bar belongs to one episode, so it restarts empty.
    position.value = Duration.zero;
    duration.value = Duration.zero;
    // Nothing is parked for this drama, so the previous player (if it was
    // parked just above) waits for its own release; a new one is created only
    // after that release finished.
    final release = _releases;

    NativePlayer? candidate;
    try {
      final episodes = await _episodesFor(contentId, tab, series);
      if (!_current(generation)) return;
      if (episodes.isEmpty) throw const ApiException('剧集列表暂时无法加载');
      Map<String, dynamic>? saved;
      try {
        saved = await _history.load(contentId);
      } catch (_) {
        // Local storage is optional for starting a video.
      }
      if (!_current(generation)) return;
      final index = (resumeEpisodeIndex(saved, episodes) ?? 0).clamp(
        0,
        episodes.length - 1,
      );
      _episodes = episodes;
      _activeIndex = index;
      final source = await _sources.request(episodes[index]).future;
      if (!_current(generation)) return;
      final uri = Uri.tryParse(source.url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        throw const ApiException('获取播放地址失败');
      }
      // A parked player is only torn down here, and only its own release is
      // awaited: the pool keeps the *other* entries alive on purpose.
      await release;
      if (!_current(generation)) return;
      final player = candidate = playerFactory?.call() ?? NativePlayer();
      _player = player;
      await player.create(source.url, source.keyHex);
      if (!_current(generation, player)) {
        if (identical(_player, player)) _player = null;
        await player.dispose();
        return;
      }
      if (player.lastError case final Object failure) throw failure;
      _subscribe(player, generation);
      textureId.value = player.textureId;
      _adoptVideoSize(player);
      rotation.value = player.videoRotationCorrection ~/ 90;
      // A new player always starts unmuted at 1x; the viewer's own choices have
      // to be pushed back on it before the first frame shows.
      await _applyPlaybackPrefs(player);
      if (!_current(generation, player)) return;
      if (player.firstFrameRendered) _onFirstFrame(player, generation);
      if (_wantsPlay) {
        await player.play();
        if (!_current(generation, player)) return;
        playing.value = _playbackRequested(player);
      }
    } catch (failure) {
      if (_current(generation)) {
        await _fail(failure);
      } else if (candidate != null) {
        // A superseded activation must not leave a native allocation behind.
        await candidate.dispose();
      }
    }
  }

  /// The pool key of one drama. Matches the official pool's per-`vid` keying
  /// (`jq3/x.java:4687 gq3.b.a.g(str2 /*vid*/, ...)`) with this app's content
  /// id, which is what a feed card stands for.
  static String _poolKey(MediaItem series) => series.seriesId ?? series.id;

  /// Drop the player subscriptions without touching the player itself. Used
  /// when a player is parked: it must stop feeding this session's notifiers,
  /// but stay alive for the pool.
  void _detachSubscriptions() {
    for (final subscription in _subs) {
      unawaited(subscription.cancel());
    }
    _subs.clear();
  }

  /// Continue a player that came back from [pool]: push the viewer's mute/rate
  /// choices again and start it if the feed wants playback.
  Future<void> _resumeReused(NativePlayer player, int generation) async {
    await _applyPlaybackPrefs(player);
    if (!_current(generation, player)) return;
    if (!_wantsPlay) return;
    try {
      await player.play();
    } catch (failure) {
      if (_current(generation, player)) await _fail(failure);
      return;
    }
    if (_current(generation, player)) {
      playing.value = _playbackRequested(player);
    }
  }

  /// Stop playback, keeping the current player so [resume] can restart it
  /// without another create. Used for a muted tab, the app going to the
  /// background, a feed drag and any route pushed on top of the feed.
  Future<void> pause() async {
    if (_disposed) return;
    _wantsPlay = false;
    final player = _player;
    if (player == null || !player.isCreated) {
      playing.value = false;
      return;
    }
    await _persistProgress();
    // Saving progress can take longer than the interruption that asked for the
    // pause: a drag that ends, a tab that comes back or a route that pops sets
    // the intent back to "wants play" while this write is still in flight. The
    // pause must not land afterwards, or the card stays frozen on its last
    // frame with nothing left to restart it.
    if (!identical(player, _player) || _wantsPlay || _disposed) return;
    try {
      await player.pause();
    } catch (_) {
      // A player that refuses to pause is about to be released anyway.
    }
    if (identical(player, _player) && !_wantsPlay) playing.value = false;
  }

  /// Restart the paused player. Does nothing after [release].
  Future<void> resume() async {
    if (_disposed) return;
    _wantsPlay = true;
    final player = _player;
    if (player == null || !player.isCreated || error.value != null) return;
    final generation = _generation;
    try {
      await player.play();
    } catch (failure) {
      if (_current(generation, player)) await _fail(failure);
      return;
    }
    if (identical(player, _player)) playing.value = _playbackRequested(player);
  }

  /// Unmute / mute the current episode. The hint pill (`mq3.c`) flips this;
  /// once unmuted the session stays unmuted across cards — the same rule as
  /// the official `needMutePlay`, which only a viewer action can turn back on.
  Future<void> toggleMute() async {
    _muted = !_muted;
    muted.value = _muted;
    final player = _player;
    if (player == null || !player.isCreated) return;
    try {
      await player.setVolume(_muted ? 0.0 : 1.0);
    } catch (_) {
      // A player that refuses a volume change is on its way out.
    }
  }

  /// Seek to [target] (`ExpandSeekBarDragFrameLayout`, the card's progress bar).
  Future<void> seek(Duration target) async {
    final player = _player;
    if (player == null || !player.isCreated) return;
    final total = player.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (total > Duration.zero && target > total ? total : target);
    position.value = clamped;
    await player.seek(clamped);
  }

  /// Long-press fast-forward. The official view holds the raised rate only
  /// while the gesture lasts and then shows 「2倍速快进中」 (`cjx.xml`).
  Future<void> setRate(double value) async {
    if (value == _rate) return;
    _rate = value;
    rate.value = value;
    final player = _player;
    if (player == null || !player.isCreated) return;
    try {
      await player.setRate(value);
    } catch (_) {
      // Same as above: a failed rate change must not break playback.
    }
  }

  /// Park the current player instead of destroying it, saving progress once.
  ///
  /// This is the swipe-away path: the official feed keeps the paused player in
  /// `ShortPlayerSharePool` under its `vid`
  /// (`jq3/x.java:4681-4690 cacheSharePlayerAndUnBindCurPlayer`), so coming back
  /// to the drama resumes the same decoder. [dispose] is the destructive one.
  ///
  /// Callers that are about to open a *second* native player (the full page
  /// player) must use [disposePlayer] instead, because two ExoPlayer instances
  /// must never be alive at once.
  Future<void> release() async {
    if (_disposed) return;
    final generation = ++_generation;
    await _persistProgress();
    // A new activation may have started while the write was in flight; it owns
    // the player and the notifiers now.
    if (_disposed || generation != _generation) return;
    activeId.value = null;
    firstFrame.value = false;
    playing.value = false;
    error.value = null;
    position.value = Duration.zero;
    duration.value = Duration.zero;
    _parkCurrent();
  }

  /// Destroy the current player **and empty the pool**, rather than parking it.
  ///
  /// Used before pushing the full page player, which creates a native instance
  /// of its own: parked decoders must go too, or the pool would keep a second
  /// (third…) ExoPlayer alive alongside the page's own.
  Future<void> disposePlayer() async {
    if (_disposed) return;
    final generation = ++_generation;
    await _persistProgress();
    if (_disposed || generation != _generation) return;
    activeId.value = null;
    firstFrame.value = false;
    playing.value = false;
    error.value = null;
    position.value = Duration.zero;
    duration.value = Duration.zero;
    await _teardown();
    await pool.releaseAll();
  }

  /// Page teardown: destroy the current player, the whole pool, the page-local
  /// directory cache and the value notifiers.
  ///
  /// The official client frees the share pool when it leaves the feed
  /// (`ShortSeriesImpl.java:165 sharePlayerPoolRelease` → `gq3/b.java:47 h()`).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    await _persistProgress();
    await _teardown();
    await pool.dispose();
    _directories.clear();
    _sources.dispose();
    activeId.dispose();
    textureId.dispose();
    firstFrame.dispose();
    playing.dispose();
    rotation.dispose();
    videoSize.dispose();
    position.dispose();
    duration.dispose();
    muted.dispose();
    rate.dispose();
    error.dispose();
  }

  /// Leave the feed entirely: destroy the current player **and** empty the pool.
  ///
  /// Used when the viewer switches to a local channel (最近 / 收藏), which has no
  /// video at all — keeping parked decoders would waste memory for a list the
  /// viewer may stay on. The official client does the same when it leaves:
  /// `ShortSeriesImpl.java:165 sharePlayerPoolRelease` → `gq3/b.java:47 h()`.
  Future<void> releaseAll() async {
    if (_disposed) return;
    await release();
    await pool.releaseAll();
  }

  /// Move the current player into [pool] under its drama's key.
  ///
  /// The player is detached from this session's notifiers but keeps decoding
  /// resources, which is exactly the trade the official pool makes. If there is
  /// no active drama there is nothing to key it by, so it is destroyed instead.
  void _parkCurrent() {
    final player = _player;
    final series = _active;
    if (player == null) return;
    _detachSubscriptions();
    _player = null;
    if (series == null || !player.isCreated) {
      unawaited(player.dispose());
      return;
    }
    pool.park(_poolKey(series), player);
  }

  void _subscribe(NativePlayer player, int generation) {
    _subs.addAll([
      player.firstFrameStream.listen((_) {
        if (_current(generation, player)) _onFirstFrame(player, generation);
      }),
      player.playWhenReadyStream.listen((_) {
        if (_current(generation, player)) {
          playing.value = _playbackRequested(player);
        }
      }),
      player.errorStream.listen((failure) {
        if (_current(generation, player)) unawaited(_fail(failure));
      }),
      player.videoSizeStream.listen((size) {
        if (!_current(generation, player)) return;
        // Refresh the rotation correction with the size: both arrive on the same
        // event, and a correction that lands after `create` would otherwise be
        // missed (rotated material would stay sideways).
        rotation.value = player.videoRotationCorrection ~/ 90;
        // A freshly created decoder reports 0×0 before the real size arrives.
        // Adopting that after a size we already trust would letterbox the video
        // as if it were 9:16 for a frame -- the same rule the orientation fix
        // applied to auto-advance (`_appliedVideoSize`).
        if (size.width <= 0 || size.height <= 0) return;
        videoSize.value = size;
      }),
      // The card's progress bar reads these two (`cjt.xml`).
      player.positionStream.listen((value) {
        if (_current(generation, player)) position.value = value;
      }),
      player.durationStream.listen((value) {
        if (_current(generation, player)) duration.value = value;
      }),
    ]);
  }

  /// Re-apply the session's mute/rate to a freshly created player.
  ///
  /// Both are viewer choices that outlive one episode, and a new `NativePlayer`
  /// always starts unmuted at 1×, so they have to be pushed again after every
  /// `create` — the same reason resume/position are re-established here.
  Future<void> _applyPlaybackPrefs(NativePlayer player) async {
    // 冷启动静音读持久化设置（官方 `open_mute_when_cold_start`，默认 false
    // ＝有声）。只在会话内第一次建播放器时读一次：之后 `_muted` 完全由用户
    // 操作接管——官方 `needMutePlay` 被用户解除后，会话内不再自动静音。
    if (!_coldStartMuteApplied) {
      _coldStartMuteApplied = true;
      await DramaMutePreferences.instance.load();
      _muted = DramaMutePreferences.instance.muteWhenColdStart.value;
      muted.value = _muted;
    }
    try {
      await player.setVolume(_muted ? 0.0 : 1.0);
    } catch (_) {
      // Volume is best effort: a player that rejects it still plays.
    }
    if (_rate != 1.0) {
      try {
        await player.setRate(_rate);
      } catch (_) {
        // Same.
      }
    }
  }

  /// Adopt the decoder's size once it is known. A 0×0 answer means "not yet"
  /// rather than portrait, so it never replaces a size we already trust.
  void _adoptVideoSize(NativePlayer player) {
    final width = player.videoWidth;
    final height = player.videoHeight;
    if (width <= 0 || height <= 0) return;
    videoSize.value = Size(width.toDouble(), height.toDouble());
  }

  void _onFirstFrame(NativePlayer player, int generation) {
    if (!_current(generation, player) || !player.firstFrameRendered) return;
    if (!_hasDisplayed) _hasDisplayed = true;
    firstFrame.value = true;
  }
  Future<void> _fail(Object failure) async {
    if (_disposed) return;
    ++_generation;
    error.value = userFacingError(failure);
    firstFrame.value = false;
    playing.value = false;
    await _teardown();
  }

  /// Detach the current player and queue its **release**. Every later creation
  /// waits for this future, so native instances are never created back to back.
  ///
  /// This is the destructive path: [release] parks a player instead, and only
  /// this method (via [disposePlayer], [dispose] and [_fail]) actually frees one.
  Future<void> _teardown() {
    final old = _player;
    _player = null;
    _episodes = const [];
    _activeIndex = null;
    _hasDisplayed = false;
    if (!_disposed) textureId.value = null;
    final cancellations = [
      for (final subscription in _subs) subscription.cancel(),
    ];
    _subs.clear();
    final release = () async {
      await Future.wait(cancellations);
      if (old != null) {
        try {
          if (old.isCreated) await old.pause();
        } finally {
          await old.dispose();
        }
      }
    }();
    _releases = Future.wait([
      _releases,
      release,
    ]).then<void>((_) {}).catchError((Object _) {});
    return _releases;
  }

  Map<String, dynamic> _historyEntry(
    MediaItem series,
    String contentId,
    int index,
    NativePlayer player,
  ) {
    final durationMs = player.duration > Duration.zero
        ? player.duration.inMilliseconds
        : 0;
    final rawPositionMs = player.position.inMilliseconds;
    final positionMs = durationMs > 0
        ? rawPositionMs.clamp(0, durationMs)
        : rawPositionMs < 0
        ? 0
        : rawPositionMs;
    return {
      'id': contentId,
      'kind': series.kind,
      'title': series.title,
      'bookId': contentId,
      'seriesId': contentId,
      'episodeId': _episodes[index].itemId,
      'chapterId': _episodes[index].itemId,
      'episode': index,
      'progress': durationMs > 0 ? positionMs / durationMs : 0.0,
      'position': positionMs / 1000,
      'duration': durationMs / 1000,
      'maxScroll': durationMs / 1000,
      'cover': series.cover,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// Saves the current episode once. Only an episode that actually produced a
  /// frame may write: `create` completing is not a usable video, and the
  /// previous resume entry must survive a failed start.
  Future<void> _persistProgress() {
    final player = _player;
    final index = _activeIndex;
    final series = _active;
    if (player == null ||
        index == null ||
        series == null ||
        index >= _episodes.length ||
        !_hasDisplayed) {
      return Future<void>.value();
    }
    final contentId = series.seriesId ?? series.id;
    return _history.save(_historyEntry(series, contentId, index, player));
  }
}
