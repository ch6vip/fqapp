import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/audio_extra.dart';
import '../models/book_comment.dart';
import '../models/book_detail.dart';
import '../models/chapter_media.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/audio_history.dart';
import '../services/chapter_cache_store.dart';
import '../services/library_store.dart';
import '../services/listening_session.dart';
import '../services/native_player.dart';
import '../services/playback_format.dart';
import '../services/shelf_store.dart';
import '../services/transient_retry.dart';
import '../widgets/audio/audio_sections.dart';
import '../widgets/audio/voice_settings_sheet.dart';
import '../widgets/chapter_cache_sheet.dart';
import '../widgets/home/home_design.dart';
import 'detail_page.dart';

/// Foreground listening using the existing Android Media3 URL player.
class AudioPage extends StatefulWidget {
  final String bookId;
  final String title;
  final String cover;
  final List<Chapter> chapters;
  final int startIndex;

  /// Where playback starts inside [startIndex]. 从本段听 sets this to the pressed
  /// paragraph's place on the chapter's spoken timeline. Null means resume from
  /// history, else the chapter opening.
  final Duration? startPosition;
  final String? initialToneId;
  final double? initialRate;
  final bool autoplay;
  final ReaderStore? historyStore;
  final NativePlayer Function()? playerFactory;
  final Future<AudioSource> Function(String itemId, {String? toneId})?
  sourceLoader;
  final Future<List<AudioVoice>> Function()? voicesLoader;

  /// 智能朗读 voices, companion works and the summary shown around the player.
  final AudioExtrasLoader? extrasLoader;

  /// 边听边读 subtitles for one chapter. Resolved with the selected tone id,
  /// because the backend only answers for a real tone.
  final SubtitleLoader? subtitleLoader;

  /// Current-chapter opening excerpt shown under the cover, mirroring the
  /// official listening page. Defaults to `/chapters/summary`.
  final Future<String?> Function(String itemId)? excerptLoader;

  /// Directory of another recording or the associated TTS novel. A version
  /// switch uses that book's own chapter IDs. Defaults to the listening API.
  final Future<List<Chapter>> Function(String bookId)? directoryLoader;

  const AudioPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.chapters,
    this.startIndex = 0,
    this.startPosition,
    this.initialToneId,
    this.initialRate,
    this.autoplay = true,
    this.cover = '',
    this.historyStore,
    this.playerFactory,
    this.sourceLoader,
    this.voicesLoader,
    this.extrasLoader,
    this.subtitleLoader,
    this.excerptLoader,
    this.directoryLoader,
  });

  @override
  State<AudioPage> createState() => _AudioPageState();
}

/// Optional listening-page decorations. A caller that already injects its own
/// source, voice or player stubs is offline by construction, so the page does
/// not reach for the network behind its back.
///
/// Note: 听书页版式复刻、字幕与音色的实测契约 — 见
/// .agents/notes/implemented/feature/2026-09-10-detail-audio-replica.md
class AudioExtras {
  const AudioExtras({
    this.tones = const AudioToneSet(),
    this.related = const [],
    this.detail,
  });

  final AudioToneSet tones;
  final List<RelatedWork> related;
  final BookDetail? detail;
}

typedef AudioExtrasLoader = Future<AudioExtras> Function(String bookId);
typedef SubtitleLoader =
    Future<SubtitleTrack> Function(String itemId, String toneId);

typedef _ReadAlongSnapshot = ({
  String chapterTitle,
  SubtitleTrack track,
  Duration position,
});

typedef _MoreSnapshot = ({bool loading, bool autoAdvance, int? sleepMinutes});

typedef _RoutePlayback = ({
  int index,
  Duration position,
  bool completed,
  bool autoplay,
});

Future<AudioExtras> _defaultAudioExtras(String bookId) async {
  final tones = await ApiClient.instance
      .bookTones(bookId)
      .catchError((Object _) => const AudioToneSet());
  final related = await ApiClient.instance
      .relatedWorks(bookId)
      .catchError((Object _) => const <RelatedWork>[]);
  final detail = await ApiClient.instance
      .bookDetail(bookId)
      .catchError((Object _) => const BookDetail());
  return AudioExtras(tones: tones, related: related, detail: detail);
}

class _AudioPageState extends State<AudioPage> with WidgetsBindingObserver {
  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static const _defaultVoice = AudioVoice(id: '0', label: '默认音色');

  late String _bookId;
  late String _title;
  late String _cover;
  late List<Chapter> _chapters;
  late int _index;
  late final AudioHistory _history;
  int _settingsGeneration = 0;
  Future<void> _settingsReady = Future<void>.value();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _listenTime = Stopwatch();
  Future<void> _releases = Future<void>.value();
  NativePlayer? _player;
  int? _activeIndex;
  bool _hasPlayed = false;
  int _generation = 0;
  int _seekGeneration = 0;
  Timer? _saveTimer;
  bool _appActive = true;
  bool _loading = true;
  bool _wantPlay = true;
  bool _completed = false;
  bool _autoAdvance = true;
  String? _error;
  String _toneId = '0';
  String _excerpt = '';
  int _excerptGeneration = 0;
  double _rate = 1;
  // The narration position ticks ~5×/s and feeds only the progress row, so
  // both are ValueNotifiers: the 5Hz stream rebuilds that row instead of the
  // whole page (cover image, tone cards, related-works list and all).
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  final ValueNotifier<double?> _seekPreview = ValueNotifier(null);
  Duration _duration = Duration.zero;
  List<AudioVoice> _voices = const [_defaultVoice];
  AudioExtras _extras = const AudioExtras();
  SubtitleTrack _subtitles = SubtitleTrack.empty;
  // Modal routes rebuild independently of the player page. See
  // .agents/notes/implemented/bug-fix/2026-09-16-cross-review-boundaries.md.
  final _readAlong = ValueNotifier<_ReadAlongSnapshot>((
    chapterTitle: '',
    track: SubtitleTrack.empty,
    position: Duration.zero,
  ));
  final _moreState = ValueNotifier<_MoreSnapshot>((
    loading: true,
    autoAdvance: true,
    sleepMinutes: null,
  ));
  Timer? _sleepTimer;
  Duration? _sleepRemaining;
  bool _inShelf = false;
  bool _switchingVersion = false;
  final Map<String, AudioSource> _audioSourceCache = {};

  void _prefetchNextAudioChapter() {
    if (widget.sourceLoader != null || !_autoAdvance || _index + 1 >= _chapters.length) return;
    final nextId = _chapters[_index + 1].itemId;
    final cacheKey = '$nextId|$_toneId';
    if (_audioSourceCache.containsKey(cacheKey)) return;
    unawaited(_loadSourceWithRetry(nextId).catchError((Object _) => AudioSource(itemId: nextId, url: '')));
  }

  /// Resolves the listening-page decorations. See [AudioExtras].
  Future<AudioExtras> _loadExtras() {
    final loader = widget.extrasLoader;
    if (loader != null) return loader(_bookId);
    if (widget.sourceLoader != null ||
        widget.voicesLoader != null ||
        widget.playerFactory != null) {
      return Future.value(const AudioExtras());
    }
    return _defaultAudioExtras(_bookId);
  }

  /// Resolves 边听边读 subtitles. Books without generated speech text answer
  /// with an empty track, so this is never treated as an error.
  Future<SubtitleTrack> _loadSubtitles(String itemId, String toneId) {
    final loader = widget.subtitleLoader;
    if (loader != null) return loader(itemId, toneId);
    if (widget.sourceLoader != null || widget.playerFactory != null) {
      return Future.value(SubtitleTrack.empty);
    }
    return ApiClient.instance.chapterTimeline(itemId, toneId: toneId);
  }

  bool _current(int generation, [NativePlayer? player]) =>
      mounted &&
      generation == _generation &&
      (player == null || identical(player, _player));

  bool get _ready =>
      !_loading && _error == null && (_player?.isCreated ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NativePlayer.setRemoteCommandHandler(
      onAction: _handleRemoteAction,
      onBecomingNoisy: _handleBecomingNoisy,
    );
    _history = AudioHistory(widget.historyStore ?? LibraryStore.instance);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _bookId = widget.bookId;
    _title = widget.title;
    _cover = widget.cover;
    _chapters = widget.chapters;
    _index = _chapters.isEmpty
        ? 0
        : widget.startIndex.clamp(0, _chapters.length - 1);
    _settingsReady = _prepareSettings();
    if (_chapters.isEmpty) {
      _loading = false;
    } else {
      unawaited(
        _openChapter(
          _index,
          restoreHistory: true,
          autoplay: widget.autoplay,
          position: widget.startPosition,
        ),
      );
    }
  }

  Future<void> _prepareSettings({String? forceToneId}) async {
    final generation = ++_settingsGeneration;
    final history = _history.load(_bookId).catchError((Object _) => null);
    final voices = () async {
      try {
        return await (widget.voicesLoader?.call() ??
                ApiClient.instance.audioVoices(_bookId))
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        return <AudioVoice>[_defaultVoice];
      }
    }();
    final extras = _loadExtrasSafely();
    final saved = await history;
    final available = await voices;
    if (!mounted || generation != _settingsGeneration) return;
    final byId = <String, AudioVoice>{'0': _defaultVoice};
    for (final voice in available) {
      if (voice.id.trim().isNotEmpty && voice.label.trim().isNotEmpty) {
        byId[voice.id] = voice;
      }
    }
    final savedTone = saved?['toneId'];
    final savedRate = saved?['rate'];
    final initialTone = widget.initialToneId?.trim();
    // Only a saved voice that the decorations endpoint knows is worth waiting
    // for before the first source request. Letting /tones, /related or /detail
    // gate playback for everyone else is the p09 defect; the wait is bounded
    // so a slow or hung decorations call can never block playback forever.
    AudioExtras? resolved;
    if ((initialTone == null || initialTone.isEmpty) &&
        savedTone is String &&
        savedTone.trim().isNotEmpty &&
        !byId.containsKey(savedTone)) {
      try {
        resolved = await extras.timeout(const Duration(seconds: 3));
      } catch (_) {
        resolved = null;
      }
      if (!mounted || generation != _settingsGeneration) return;
      if (resolved != null) _mergeToneVoices(resolved, byId);
    }
    setState(() {
      if (resolved != null) _extras = resolved;
      _voices = List.unmodifiable(byId.values);
      if (generation == 1) {
        if (savedTone is String && byId.containsKey(savedTone)) {
          _toneId = savedTone;
        }
        if (initialTone != null && initialTone.isNotEmpty) {
          _toneId = initialTone;
        }
        if (savedRate is num &&
            savedRate.isFinite &&
            _rates.contains(savedRate.toDouble())) {
          _rate = savedRate.toDouble();
        }
        final initialRate = widget.initialRate;
        if (initialRate != null && _rates.contains(initialRate)) {
          _rate = initialRate;
        }
      }
      if (forceToneId != null && forceToneId.isNotEmpty) {
        _toneId = forceToneId;
      }
      if (saved?['autoAdvance'] case final bool enabled) {
        _autoAdvance = enabled;
      }
      // 是否已在书架以本地收藏库为准；收藏库不可用时退回历史里的旧字段，
      // 以免没有 Hive 的环境丢掉标记。
      _inShelf = _resolveShelf(saved);
    });
    _publishMoreState();
    unawaited(_publishExtras(extras, generation));
  }

  Future<AudioExtras> _loadExtrasSafely() async {
    try {
      return await _loadExtras().timeout(const Duration(seconds: 10));
    } catch (_) {
      return const AudioExtras();
    }
  }

  /// Mirrors the upstream tone list as-is: same names, same order. Two
  /// different tones may share a display name (the official panel shows them
  /// as two cards distinguished by their description); the ids stay distinct.
  List<AudioTone> _uniqueTones(List<AudioTone> tones) {
    final seen = <String>{};
    final out = <AudioTone>[];
    for (final tone in tones) {
      if (!seen.add('${tone.id}\u0000${tone.title}')) continue;
      out.add(tone);
    }
    return out;
  }

  void _mergeToneVoices(AudioExtras loaded, Map<String, AudioVoice> byId) {
    // Real tone names beat the CSV fallback's placeholder labels. 真人讲书
    // narrators only arrive here; their ids were resolved exactly by
    // AudioToneSet.fromPayload, which drops any unresolved narrator.
    final tones = _uniqueTones([
      ...loaded.tones.ttsTones,
      ...loaded.tones.narratorTones,
    ]);
    final labels = <String, String>{
      for (final voice in byId.values) voice.label: voice.id,
    };
    for (final tone in tones) {
      final id = tone.id.trim();
      final title = tone.title.trim();
      if (id.isEmpty || title.isEmpty) continue;
      var label = title;
      if (labels.containsKey(label) && labels[label] != id) {
        label = '$title（$id）';
        var bump = 2;
        while (labels.containsKey(label) && labels[label] != id) {
          label = '$title（$id·${bump++})';
        }
      }
      labels[label] = id;
      byId[id] = AudioVoice(id: id, label: label);
    }
  }

  Future<void> _publishExtras(
    Future<AudioExtras> extras, [
    int? generation,
  ]) async {
    AudioExtras loaded;
    try {
      loaded = await extras;
    } catch (_) {
      loaded = const AudioExtras();
    }
    if (!mounted) return;
    if (generation != null && generation != _settingsGeneration) return;
    final byId = <String, AudioVoice>{
      for (final voice in _voices) voice.id: voice,
    };
    _mergeToneVoices(loaded, byId);
    setState(() {
      _extras = loaded;
      _voices = List.unmodifiable(byId.values);
    });
  }

  void _syncForeground() {
    if (!mounted || _index < 0 || _index >= _chapters.length) return;
    final isPlaying =
        (_player?.playing ?? false) && _wantPlay && !_completed && !_loading;
    unawaited(
      NativePlayer.startListenForeground(
        title: _title,
        episode: _chapters[_index].title,
        playing: isPlaying,
        hasPrev: _index > 0,
        hasNext: _index < _chapters.length - 1,
      ),
    );
  }

  void _handleRemoteAction(String action) {
    if (!mounted) return;
    switch (action) {
      case 'playPause':
        unawaited(_togglePlayback());
      case 'prev':
        if (_index > 0) unawaited(_openChapter(_index - 1));
      case 'next':
        if (_index < _chapters.length - 1) unawaited(_openChapter(_index + 1));
      case 'stop':
        final player = _player;
        if (player != null && player.isCreated) {
          setState(() => _wantPlay = false);
          _listenTime.stop();
          unawaited(_pause(player, _generation));
        }
    }
  }

  void _handleBecomingNoisy() {
    if (!mounted) return;
    final player = _player;
    if (player != null && player.isCreated && _wantPlay) {
      setState(() => _wantPlay = false);
      _listenTime.stop();
      unawaited(_pause(player, _generation));
      _syncForeground();
    }
  }

  @override
  void dispose() {
    ListeningSession.instance.clear();
    NativePlayer.clearRemoteCommandHandler();
    unawaited(NativePlayer.stopListenForeground());
    WidgetsBinding.instance.removeObserver(this);
    ++_generation;
    ++_seekGeneration;
    _saveTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepTimerTick?.cancel();
    _listenTime.stop();
    unawaited(_persistProgress());
    unawaited(_releasePlayer());
    _readAlong.dispose();
    _moreState.dispose();
    _position.dispose();
    _seekPreview.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (!_appActive) {
      // 切换到后台或锁屏时立即持久化当前进度，防止后续被系统杀后台导致进度丢失。
      // 后台保持播放（由 ListenKeepAliveService 前台服务保活）。
      unawaited(_persistProgress());
    }
    _syncListenClock();
    if (mounted) setState(() {});
  }

  Future<void> _openChapter(
    int index, {
    bool restoreHistory = false,
    Duration? position,
    String? toneId,
    bool autoplay = true,
    bool? completed,
    bool persistCurrent = true,
  }) async {
    if (!mounted || index < 0 || index >= _chapters.length) return;
    final generation = ++_generation;
    ++_seekGeneration;
    _saveTimer?.cancel();
    _listenTime.stop();
    if (persistCurrent) unawaited(_persistProgress());
    final released = _releasePlayer();
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _completed = false;
      _position.value = position ?? Duration.zero;
      _duration = Duration.zero;
      _seekPreview.value = null;
      _subtitles = SubtitleTrack.empty;
      _wantPlay = autoplay;
    });
    _publishReadAlong();
    _publishMoreState();
    unawaited(_loadExcerpt(_chapters[index].itemId));
    NativePlayer? candidate;
    try {
      await _settingsReady;
      if (!_current(generation)) return;
      if (toneId != null) _toneId = toneId;
      Map<String, dynamic>? saved;
      if (restoreHistory) {
        try {
          saved = await _history.load(_bookId);
        } catch (_) {
          // Listening can still start when local storage is unavailable.
        }
      }
      if (!_current(generation)) return;
      final sameChapter = resumeAudioChapterIndex(saved, _chapters) == index;
      final resume =
          position ??
          (sameChapter ? _savedDuration(saved?['position']) : Duration.zero);
      final savedDuration = sameChapter
          ? _savedDuration(saved?['duration'])
          : Duration.zero;
      // A position handed in from outside is a deliberate start point, not a
      // resume: the chapter's saved "played to the end" state must not turn it
      // into a replay-from-zero or a skip to the next chapter.
      // A start position handed in from outside is a deliberate new start, not
      // a resume: a chapter saved as "played to the end" must not turn it into
      // a replay-from-zero on the next play tap, nor skip to the next chapter.
      final wasCompleted =
          completed ??
          (position == null && sameChapter && saved?['completed'] == true);
      final itemId = _chapters[index].itemId;
      final source = await _loadSourceWithRetry(itemId);
      if (!_current(generation)) return;
      final uri = Uri.tryParse(source.url);
      if (source.itemId != itemId ||
          uri == null ||
          !const ['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw const FormatException('Invalid audio source');
      }
      await released;
      if (!_current(generation)) return;
      final player = candidate = widget.playerFactory?.call() ?? NativePlayer();
      _player = player;
      await player.create(source.url, source.keyHex);
      if (!_current(generation, player)) {
        await player.dispose();
        return;
      }
      if (player.lastError case final Object error) throw error;
      _subscribe(player, generation);
      await player.setRate(_rate);
      if (!_current(generation, player)) return;
      final duration = player.duration > Duration.zero
          ? player.duration
          : (source.duration ?? Duration.zero) > Duration.zero
          ? source.duration!
          : savedDuration;
      final restoredPosition = _boundedPosition(resume, duration);
      if (restoredPosition > Duration.zero) {
        await player.seek(restoredPosition);
        if (!_current(generation, player)) return;
      }
      setState(() {
        _activeIndex = index;
        _toneId = source.toneId;
        _duration = duration;
        _position.value = _boundedPosition(player.position, duration);
        _completed = wasCompleted;
        if (wasCompleted) _wantPlay = false;
        _loading = false;
      });
      _publishReadAlong();
      _publishMoreState();
      // Subtitles are decoration: they arrive whenever the book has generated
      // speech text and are ignored otherwise.
      unawaited(_refreshSubtitles(generation, itemId, source.toneId));
      if (_wantPlay) await _play(player, generation);
      if (!_current(generation, player)) return;
      _syncForeground();
      _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (player.playing) unawaited(_persistProgress());
      });
      _syncListenClock();
    } catch (error) {
      if (_current(generation)) {
        _fail(error, generation);
      } else {
        await candidate?.dispose();
      }
    }
  }

  /// Fetches one chapter's audio source.
  ///
  /// The backend picks a pooled device per upstream request and the audio
  /// player host sometimes answers a body-level 403 for it, so the network
  /// path retries a few draws before the page reports a failure. An injected
  /// loader is exact and is never multiplied.
  ///
  /// A pure-TTS book has no default voice: the playinfo endpoint answers
  /// NO_THIS_TONE for tone 0, so the first selectable voice is retried once.
  Future<AudioSource> _loadSourceWithRetry(String itemId) async {
    final loader = widget.sourceLoader;
    if (loader != null) {
      return loader(
        itemId,
        toneId: _toneId,
      ).timeout(const Duration(seconds: 30));
    }
    final cacheKey = '$itemId|$_toneId';
    final cached = _audioSourceCache[cacheKey];
    if (cached != null) return cached;
    final toneId = _toneId;
    AudioSource result;
    try {
      result = await retryTransient(
        () => ApiClient.instance
            .audioSource(itemId, bookId: _bookId, toneId: toneId)
            .timeout(const Duration(seconds: 30)),
      );
    } on ApiException catch (error) {
      if (toneId != '0' ||
          !error.message.contains('NO_THIS_TONE') ||
          !_current(_generation)) {
        rethrow;
      }
      final fallback = _firstSelectableTone();
      if (fallback == null) rethrow;
      final tone = fallback;
      result = await retryTransient(
        () => ApiClient.instance
            .audioSource(itemId, bookId: _bookId, toneId: tone)
            .timeout(const Duration(seconds: 30)),
      );
    }
    _audioSourceCache[cacheKey] = result;
    while (_audioSourceCache.length > 5) {
      _audioSourceCache.remove(_audioSourceCache.keys.first);
    }
    return result;
  }

  /// First non-default voice the page knows, for books without a default one.
  String? _firstSelectableTone() {
    for (final tone in _extras.tones.ttsTones) {
      if (tone.id.trim().isNotEmpty) return tone.id;
    }
    for (final tone in _extras.tones.narratorTones) {
      if (tone.id.trim().isNotEmpty) return tone.id;
    }
    for (final voice in _voices) {
      if (voice.id != '0' && voice.id.trim().isNotEmpty) return voice.id;
    }
    return null;
  }

  /// Loads the 边听边读 track for a chapter and publishes it if the chapter is
  /// still the active one.
  Future<void> _refreshSubtitles(
    int generation,
    String itemId,
    String toneId,
  ) async {
    try {
      final track = await _loadSubtitles(itemId, toneId);
      if (!_current(generation)) return;
      _subtitles = track;
      _publishReadAlong();
    } catch (_) {
      // Optional timeline failures must not escape the unawaited request or
      // interrupt playback. The chapter was already reset to an empty track.
    }
  }

  void _publishReadAlong() {
    if (!mounted || _index < 0 || _index >= _chapters.length) return;
    final preview = _seekPreview.value;
    _readAlong.value = (
      chapterTitle: _chapters[_index].title,
      track: _subtitles,
      position: preview == null
          ? _position.value
          : Duration(milliseconds: preview.round()),
    );
  }

  void _publishMoreState() {
    if (!mounted) return;
    _moreState.value = (
      loading: _loading,
      autoAdvance: _autoAdvance,
      sleepMinutes: _sleepRemaining?.inMinutes,
    );
  }

  static Duration _savedDuration(Object? value) {
    if (value is! num || !value.isFinite || value <= 0) return Duration.zero;
    final milliseconds = value * 1000;
    if (!milliseconds.isFinite || milliseconds >= 0x7fffffffffffffff) {
      return Duration.zero;
    }
    return Duration(milliseconds: milliseconds.round());
  }

  /// Publishes the current narration state so an open reader can follow the
  /// playback (听书跟随翻页).
  void _publishListeningSession({bool playing = true}) {
    if (_index < 0 || _index >= _chapters.length) return;
    final chapter = _chapters[_index];
    ListeningSession.instance.update(
      bookId: _bookId,
      chapterId: chapter.itemId,
      chapterTitle: chapter.title,
      position: _boundedPosition(_player?.position ?? _position.value, _duration),
      duration: _duration,
      playing: playing && !_completed,
    );
  }

  static Duration _boundedPosition(Duration position, Duration duration) {
    if (position < Duration.zero) return Duration.zero;
    return duration > Duration.zero && position > duration
        ? duration
        : position;
  }

  void _subscribe(NativePlayer player, int generation) {
    _subscriptions.addAll([
      player.positionStream.listen((position) {
        if (!_current(generation, player)) return;
        // Notifier-only: the 5Hz tick rebuilds the progress row, not the page.
        _position.value = _boundedPosition(position, _duration);
        _publishReadAlong();
        // Publish the REAL playing state: a paused seek also fires this
        // stream, and publishing playing=true would yank the reader back to
        // the narrated page while paused.
        _publishListeningSession(playing: player.playing);
      }),
      player.durationStream.listen((duration) {
        if (!_current(generation, player) || duration <= Duration.zero) return;
        setState(() {
          _duration = duration;
          _position.value = _boundedPosition(_position.value, duration);
        });
        _publishReadAlong();
      }),
      player.playingStream.listen((playing) {
        if (!_current(generation, player)) return;
        // Creation acknowledges prepare(), and API duration can be known
        // before the CDN is readable. Keep the last successful chapter until
        // this candidate actually starts foreground playback.
        if (playing &&
            !_hasPlayed &&
            _activeIndex == _index &&
            _wantPlay) {
          _hasPlayed = true;
          unawaited(_persistProgress());
        }
        _syncListenClock();
        _syncForeground();
        _publishListeningSession(playing: playing && _wantPlay);
        setState(() {});
      }),
      player.bufferingStream.listen((_) {
        if (!_current(generation, player)) return;
        _syncListenClock();
        setState(() {});
      }),
      player.completedStream.listen((completed) {
        if (!_current(generation, player) ||
            _activeIndex != _index ||
            !completed ||
            _completed) {
          return;
        }
        final shouldAdvance = _wantPlay && _autoAdvance;
        setState(() {
          _completed = true;
          _wantPlay = false;
          _position.value = _boundedPosition(player.position, _duration);
        });
        _publishReadAlong();
        _listenTime.stop();
        _syncForeground();
        unawaited(_persistProgress());
        if (shouldAdvance && _index + 1 < _chapters.length) {
          unawaited(_openChapter(_index + 1));
        } else {
          unawaited(_pause(player, generation));
        }
        // _openChapter resets completion before its source is ready.
        // The next player's playing event will publish the actual start.
        _publishListeningSession(playing: false);
      }),
      player.errorStream.listen((error) => _fail(error, generation)),
    ]);
  }

  void _syncListenClock() {
    final player = _player;
    if (_wantPlay &&
        !_completed &&
        !_loading &&
        _error == null &&
        player != null &&
        player.playing &&
        !player.buffering) {
      _listenTime.start();
      _prefetchNextAudioChapter();
    } else {
      _listenTime.stop();
    }
  }

  Future<void> _persistProgress() {
    final player = _player;
    final index = _activeIndex;
    if (player == null || index == null || !_hasPlayed) {
      return Future<void>.value();
    }
    final duration = player.duration > Duration.zero
        ? player.duration
        : _duration;
    final position = _boundedPosition(player.position, duration);
    final seconds =
        _listenTime.elapsedMicroseconds / Duration.microsecondsPerSecond;
    _listenTime.reset();
    return _history.save({
      'id': _bookId,
      'bookId': _bookId,
      'kind': 'audio',
      'title': _title,
      'cover': _cover,
      'chapterId': _chapters[index].itemId,
      'episodeId': _chapters[index].itemId,
      'episode': index,
      'position': position.inMilliseconds / 1000,
      'duration': duration.inMilliseconds / 1000,
      'maxScroll': duration.inMilliseconds / 1000,
      'progress': duration > Duration.zero
          ? position.inMilliseconds / duration.inMilliseconds
          : 0.0,
      'toneId': _toneId,
      'rate': _rate,
      'autoAdvance': _autoAdvance,
      'inShelf': _inShelf,
      'completed': _completed,
      'time': DateTime.now().millisecondsSinceEpoch,
    }, listenedSeconds: seconds);
  }

  Future<void> _releasePlayer() {
    final player = _player;
    _player = null;
    _activeIndex = null;
    _hasPlayed = false;
    final cancellations = [
      for (final sub in _subscriptions) sub.cancel().catchError((Object _) {}),
    ];
    _subscriptions.clear();
    _releases = _releases.then((_) async {
      await Future.wait(cancellations);
      if (player == null) return;
      try {
        if (player.isCreated) await player.pause();
      } catch (_) {
        // Release still has to run if the platform cannot acknowledge pause.
      }
      try {
        await player.dispose();
      } catch (_) {
        // The Flutter engine may already be shutting down.
      }
    });
    return _releases;
  }

  void _fail(Object error, int generation) {
    if (!_current(generation)) return;
    ListeningSession.instance.clear();
    unawaited(NativePlayer.stopListenForeground());
    ++_generation;
    _saveTimer?.cancel();
    _listenTime.stop();
    unawaited(_persistProgress());
    unawaited(_releasePlayer());
    setState(() {
      _loading = false;
      _wantPlay = false;
      // Signed URLs and backend response bodies must not appear in the UI.
      _error = error is TimeoutException
          ? '加载超时，请检查网络后重试。'
          : '音频暂时无法播放，请重试或切换其他章节。';
    });
    _publishMoreState();
  }

  Future<void> _play(NativePlayer player, int generation) async {
    if (!_current(generation, player) || !_wantPlay) return;
    await player.play();
    if (!_current(generation, player)) return;
    if (!_wantPlay) await player.pause();
    if (!_current(generation, player)) return;
    _syncListenClock();
    _syncForeground();
    setState(() {});
  }

  Future<void> _pause(NativePlayer player, int generation) async {
    _publishListeningSession(playing: false);
    try {
      await player.pause();
      if (_current(generation, player)) {
        await _persistProgress();
        _syncForeground();
      }
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (!_ready || player == null) return;
    final generation = _generation;
    if (_wantPlay) {
      setState(() => _wantPlay = false);
      _listenTime.stop();
      await _pause(player, generation);
      _syncForeground();
      return;
    }
    // A replay seek must remain cancellable by backgrounding or pausing.
    setState(() => _wantPlay = true);
    try {
      if (_completed) {
        await player.seek(Duration.zero);
        if (!_current(generation, player)) return;
        setState(() {
          _position.value = Duration.zero;
          _completed = false;
        });
        _publishReadAlong();
      }
      await _play(player, generation);
      if (_current(generation, player)) {
        await _persistProgress();
        _syncForeground();
      }
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<void> _seekTo(Duration position) async {
    final player = _player;
    if (!_ready || player == null) return;
    final generation = _generation;
    final seekGeneration = ++_seekGeneration;
    final target = _boundedPosition(position, _duration);
    _seekPreview.value = target.inMilliseconds.toDouble();
    _publishReadAlong();
    try {
      await player.seek(target);
      if (!_current(generation, player) || seekGeneration != _seekGeneration) {
        return;
      }
      setState(() {
        _completed = false;
      });
      _seekPreview.value = null;
      _position.value = target;
      _publishReadAlong();
      await _persistProgress();
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<void> _setRate(double rate) async {
    final player = _player;
    if (!_ready || player == null) return;
    final generation = _generation;
    // Carry the selected speed into a chapter opened before this reply.
    setState(() => _rate = rate);
    try {
      await player.setRate(rate);
      if (!_current(generation, player)) return;
      await _persistProgress();
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<void> _showRates() async {
    final rate = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('播放速度')),
            for (final rate in _rates)
              ListTile(
                title: Text('${_rateLabel(rate)}×'),
                trailing: rate == _rate ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, rate),
              ),
          ],
        ),
      ),
    );
    if (mounted && rate != null) await _setRate(rate);
  }

  Future<void> _showVoices() async {
    if (_switchingVersion) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.72,
        child: VoiceSettingsSheet(
          selectedId: _extras.tones.hasFixedTone ? _bookId : _toneId,
          narrators: _narratorOptions(),
          online: _onlineOptions(),
          onSelect: (option) {
            unawaited(_applyVoiceOption(option, fromSheet: sheetContext));
          },
        ),
      ),
    );
  }

  /// A 真人讲书 row names another book. Keep the sheet up for a cross-book
  /// switch so the recording page never flashes underneath.
  Future<void> _applyVoiceOption(
    VoiceOption option, {
    BuildContext? fromSheet,
  }) async {
    if (!mounted || _switchingVersion) return;
    for (final narrator in _narratorTones) {
      if (narrator.id == option.id) {
        if (narrator.id == _bookId) {
          _popSheet(fromSheet);
          return;
        }
        await _switchBookVersion(
          narrator.id,
          title: narrator.title,
          cover: _cover,
          toneId: '0',
          replaceContext: fromSheet,
        );
        return;
      }
    }
    await _selectTone(option.id, replaceContext: fromSheet);
  }

  void _popSheet(BuildContext? sheet) {
    if (sheet != null && sheet.mounted) Navigator.pop(sheet);
  }

  List<VoiceOption> _narratorOptions() => [
    for (final tone in _uniqueTones(_extras.tones.narratorTones))
      VoiceOption(
        id: tone.id,
        title: tone.title,
        description: tone.description,
        badge: tone.badge,
      ),
  ];

  /// 智能朗读 grid: mirrors the upstream `tts_tones` list as-is — same names,
  /// same order — but only the voices playinfo can actually serve.
  ///
  /// The `tts_tones` list *is* the selectable set: every id it carries answers
  /// a distinct stream (verified against the live playinfo endpoint). Three
  /// other sources must never reach the panel:
  ///
  ///  * the synthetic `0` / 默认音色 row [parseAudioVoices] always adds, which
  ///    a pure-TTS book answers with `NO_THIS_TONE`;
  ///  * offline (`offline_tts_tones`) ids, which playinfo rejects outright —
  ///    they require the offline download path;
  ///  * 真人讲书 (`audio_tones`) ids, which are `abook_id`s and are likewise
  ///    rejected when used as a `tone_id`.
  ///
  /// When `/tones` is unavailable the detail CSV still lists real tone ids, so
  /// it is used as a fallback rather than offering nothing at all.
  List<VoiceOption> _onlineOptions() {
    final ids = <String>{};
    final options = <VoiceOption>[
      for (final tone in _uniqueTones(_ttsTones))
        if (_selectableTone(tone.id) && ids.add(tone.id))
          VoiceOption(
            id: tone.id,
            title: tone.title,
            description: tone.description,
            badge: tone.badge,
            isMultiTone: tone.isMultiTone,
          ),
    ];
    if (options.isNotEmpty) return options;
    for (final voice in _voices) {
      if (!_selectableTone(voice.id) || !ids.add(voice.id)) continue;
      options.add(VoiceOption(id: voice.id, title: voice.label));
    }
    return options;
  }

  /// Whether a voice can be selected for playback at all.
  ///
  /// A fixed recording needs an exact associated novel before its TTS voices
  /// can be offered. `0` is synthetic; narrator and offline IDs use other paths.
  bool _selectableTone(String toneId) {
    if (_ttsBookId == null) return false;
    final id = toneId.trim();
    if (id.isEmpty || id == '0') return false;
    if (_narratorTones.any((tone) => tone.id == id)) return false;
    if (_extras.tones.offlineTones.any((tone) => tone.id == id)) return false;
    return true;
  }

  Future<void> _showCatalog() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) =>
          _AudioCatalog(chapters: _chapters, currentIndex: _index),
    );
    if (!mounted || selected == null || selected == _index) return;
    await _openChapter(selected);
  }

  static String _rateLabel(double rate) => formatPlaybackRate(rate);

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (_chapters.isEmpty) {
      return Scaffold(
        key: ValueKey('audio_session_$_bookId'),
        backgroundColor: palette.canvas,
        appBar: AppBar(
          backgroundColor: palette.canvas,
          surfaceTintColor: Colors.transparent,
          title: const Text('听书'),
        ),
        body: Center(
          child: Text('暂无可播放章节', style: TextStyle(color: palette.muted)),
        ),
      );
    }
    final chapter = _chapters[_index];
    final tones = _mode == 'narrator' ? _narratorTones : _ttsTones;
    return Scaffold(
      key: ValueKey('audio_session_$_bookId'),
      backgroundColor: palette.canvas,
      body: SafeArea(
        child: Column(
          children: [
            AudioTopBar(
              onCollapse: () => Navigator.maybePop(context),
              onMore: _showMore,
              onInspire: _showMore,
            ),
            Expanded(
              child: SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 10),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: AudioBookCard(
                            cover: _cover,
                            bookTitle: _title,
                            chapterTitle: chapter.title,
                            onSwitch: _showVoices,
                            onOpenBook: _showCatalog,
                          ),
                        ),
                        if (_excerpt.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          AudioExcerpt(text: _excerpt, onTap: _showExcerpt),
                        ],
                        if (_error != null ||
                            _loading ||
                            (_player?.buffering ?? false) ||
                            _completed) ...[
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: _statusLine(palette),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: AudioActionRow(actions: _actions),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: ValueListenableBuilder<Duration>(
                            valueListenable: _position,
                            builder: (context, position, _) =>
                                ValueListenableBuilder<double?>(
                              valueListenable: _seekPreview,
                              builder: (context, seekPreview, _) =>
                                  AudioProgressRow(
                                position: position,
                                duration: _duration,
                                preview: seekPreview,
                                enabled: _ready,
                                onChanged: (value) =>
                                    _seekPreview.value = value,
                                onChangeEnd: (value) => _seekTo(
                                  Duration(milliseconds: value.round()),
                                ),
                                onBack15: _ready
                                    ? () => _seekTo(
                                        _position.value -
                                            const Duration(seconds: 15),
                                      )
                                    : null,
                                onForward15: _ready
                                    ? () => _seekTo(
                                        _position.value +
                                            const Duration(seconds: 15),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        _transport(),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: AudioToneSection(
                            title: _mode == 'narrator' ? '真人讲书' : '智能朗读',
                            tones: tones,
                            selectedId: _extras.tones.hasFixedTone
                                ? _bookId
                                : _toneId,
                            currentChapterTitle: chapter.title,
                            onSelect: _onToneSelected,
                            onReadAlong: _showReadAlong,
                            onShowVoices: _switchingVersion
                                ? null
                                : _showVoices,
                          ),
                        ),
                        if (_extras.related.isNotEmpty) ...[
                          const SizedBox(height: 18),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: AudioRelatedRow(
                              works: _extras.related,
                              onTap: _openRelated,
                            ),
                          ),
                        ],
                        const SizedBox(height: 28),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// TTS plays on the ebook's chapter IDs, even when the panel was opened
  /// from a fixed recording. Never send its tone to the recording's chapters.
  String? get _ttsBookId {
    if (!_extras.tones.hasFixedTone) return _bookId;
    final id = _extras.tones.relatedNovel?.id;
    return id != null && id.isNotEmpty && id != _bookId ? id : null;
  }

  List<AudioTone> get _ttsTones =>
      _ttsBookId == null ? const [] : _extras.tones.ttsTones;
  List<AudioTone> get _narratorTones => _extras.tones.narratorTones;

  /// Current family, derived from the selected tone so the voice card always
  /// describe what is actually playing: `tts` (智能朗读) or `narrator` (真人讲书).
  ///
  /// A fixed recording starts on its narrator. Selecting intelligent reading
  /// opens the associated novel instead of relabeling the current recording.
  String get _mode =>
      _extras.tones.hasFixedTone ||
          _narratorTones.any((tone) => tone.id == _toneId)
      ? 'narrator'
      : 'tts';

  Future<void> _loadExcerpt(String itemId) async {
    final generation = ++_excerptGeneration;
    String? text;
    if (widget.excerptLoader != null) {
      try {
        text = await widget.excerptLoader!(itemId);
      } catch (_) {
        text = null;
      }
    } else if (!_offline) {
      try {
        final summary = await ApiClient.instance.chapterSummaries(_bookId, [
          itemId,
        ]);
        text = summary.forItem(itemId);
      } catch (_) {
        text = null;
      }
    }
    if (!mounted || generation != _excerptGeneration) return;
    setState(() => _excerpt = text?.trim() ?? '');
  }

  bool get _offline =>
      widget.sourceLoader != null ||
      widget.voicesLoader != null ||
      widget.playerFactory != null ||
      widget.extrasLoader != null;

  Future<void> _showExcerpt() async {
    if (_excerpt.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: SingleChildScrollView(
            child: Text(
              _excerpt,
              style: TextStyle(
                color: HomePalette.of(context).ink,
                fontSize: 15,
                height: 1.7,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 边听边读 entry: the official page switches to the read-along view; here the
  /// subtitle track opens in a sheet instead of pushing a route.
  Future<void> _showReadAlong() async {
    final palette = HomePalette.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ValueListenableBuilder<_ReadAlongSnapshot>(
        valueListenable: _readAlong,
        builder: (context, snapshot, _) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    snapshot.chapterTitle,
                    key: const ValueKey('audio-read-along-chapter'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: palette.ink, fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: snapshot.track.isEmpty
                        ? Center(
                            child: Text(
                              '本章暂无同步字幕',
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 13,
                              ),
                            ),
                          )
                        : SingleChildScrollView(
                            child: AudioSubtitleView(
                              track: snapshot.track,
                              position: snapshot.position,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Icon row: 语速 / 加入书架 / 下载 / 章评 / 更多.
  List<AudioAction> get _actions => [
    AudioAction(
      key: 'audio-speed',
      icon: LucideIcons.gauge,
      label: '语速',
      onTap: _ready ? _showRates : null,
    ),
    AudioAction(
      key: 'audio_shelf',
      icon: LucideIcons.book_plus,
      label: _inShelf ? '已在书架' : '加入书架',
      active: _inShelf,
      onTap: _toggleShelf,
    ),
    AudioAction(
      key: 'audio_download',
      icon: LucideIcons.download,
      label: '下载',
      onTap: _showDownload,
    ),
    AudioAction(
      key: 'audio_chapter_comment',
      icon: LucideIcons.message_circle,
      // The official listening page labels this 章评 (chapter-end discussion).
      // The closest sheet we have today shows the work's book reviews; the
      // reader keeps the real chapter/paragraph ideas.
      label: '章评',
      onTap: _showBookReviews,
    ),
    AudioAction(
      key: 'audio_more',
      icon: LucideIcons.ellipsis,
      label: '更多',
      onTap: _showMore,
    ),
  ];

  /// 目录 / 上一章 / 播放暂停 / 下一章 / 定时.
  Widget _transport() {
    final palette = HomePalette.of(context);
    final playing = _wantPlay && !_completed;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _TransportButton(
          icon: LucideIcons.list,
          tooltip: '目录',
          onTap: _showCatalog,
        ),
        _TransportButton(
          icon: LucideIcons.skip_back,
          tooltip: '上一章',
          onTap: _index > 0 ? () => _openChapter(_index - 1) : null,
        ),
        Semantics(
          button: true,
          child: IconButton(
            tooltip: playing ? '暂停' : '播放',
            onPressed: _ready ? _togglePlayback : null,
            padding: const EdgeInsets.all(11),
            iconSize: 38,
            style: IconButton.styleFrom(
              foregroundColor: palette.ink,
              disabledForegroundColor: palette.muted.withValues(alpha: 0.5),
            ),
            icon: Icon(playing ? LucideIcons.pause : LucideIcons.play),
          ),
        ),
        _TransportButton(
          icon: LucideIcons.skip_forward,
          tooltip: '下一章',
          onTap: _index + 1 < _chapters.length
              ? () => _openChapter(_index + 1)
              : null,
        ),
        _TransportButton(
          icon: LucideIcons.alarm_clock,
          tooltip: '定时',
          active: _sleepRemaining != null,
          onTap: _showSleepTimer,
        ),
      ],
    );
  }

  Widget _statusLine(HomePalette palette) {
    if (_error case final message?) {
      return Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          FilledButton.icon(
            key: const ValueKey('audio-retry'),
            onPressed: () => _openChapter(_index, restoreHistory: true),
            style: FilledButton.styleFrom(backgroundColor: HomePalette.accent),
            icon: const Icon(LucideIcons.refresh_cw, size: 16),
            label: const Text('重试'),
          ),
        ],
      );
    }
    if (_loading || (_player?.buffering ?? false)) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox.square(
            dimension: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: HomePalette.accent,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _loading ? '正在加载音频…' : '缓冲中…',
            style: TextStyle(color: palette.muted, fontSize: 12.5),
          ),
        ],
      );
    }
    return Text(
      _completed ? '本章已播完' : (_wantPlay ? '正在播放' : '已暂停'),
      textAlign: TextAlign.center,
      style: TextStyle(color: palette.muted, fontSize: 12.5),
    );
  }

  Future<void> _selectTone(
    String toneId, {
    BuildContext? replaceContext,
  }) async {
    if (_switchingVersion || !_selectableTone(toneId)) return;
    final novel = _extras.tones.relatedNovel;
    if (_ttsBookId != _bookId && novel != null) {
      await _switchBookVersion(
        novel.id,
        title: novel.title.isEmpty ? _title : novel.title,
        cover: novel.cover.isEmpty ? _cover : novel.cover,
        toneId: toneId,
        replaceContext: replaceContext,
      );
      return;
    }
    _popSheet(replaceContext);
    if (toneId == _toneId) return;
    await _openChapter(
      _index,
      position: _player?.position ?? _position.value,
      toneId: toneId,
      autoplay: _wantPlay,
      completed: _completed,
    );
  }

  /// 听书条目的归一化模型：本地收藏库同时服务书架页与这一页。
  MediaItem get _shelfItem => MediaItem(
    id: _bookId,
    title: _title,
    cover: _cover,
    author: '',
    badge: '',
    ep: _chapters.isEmpty ? '' : '${_chapters.length}',
    kind: 'audio',
  );

  /// 以 [ShelfStore] 为准；收藏库没起来时（例如纯离线测试环境）退回历史里的
  /// 旧 `inShelf` 字段。
  bool _resolveShelf(Map<String, dynamic>? saved) {
    final store = ShelfStore.instance;
    if (store.isReady) return store.containsItem(_shelfItem);
    return saved?['inShelf'] == true;
  }

  Future<void> _toggleShelf() async {
    final store = ShelfStore.instance;
    final next = store.isReady ? await store.toggle(_shelfItem) : !_inShelf;
    if (!mounted) return;
    setState(() => _inShelf = next);
    // The shelf flag is independent of playback, so it is written even when
    // nothing has been played yet in this session. The history copy stays as
    // the legacy mirror of the flag.
    try {
      final existing =
          await _history.load(_bookId) ?? const <String, dynamic>{};
      await _history.save({
        ...existing,
        'id': _bookId,
        'bookId': _bookId,
        'kind': 'audio',
        'title': _title,
        'cover': _cover,
        'inShelf': next,
      });
    } on Exception {
      // A storage failure must not desync the visible toggle.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(next ? '已加入书架' : '已移出书架'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Caches the book's chapters for offline listening/reading.
  Future<void> _showDownload() async {
    final cache = ChapterCacheStore.instance;
    final book = CachedBook(
      id: _bookId,
      title: _title,
      cover: _cover,
      chapters: _chapters,
    );
    try {
      await cache.saveBook(book);
    } on Exception {
      // A cache index failure must not block the sheet.
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => ChapterCacheSheet(
        book: book,
        currentIndex: _index,
        cache: cache,
        loader: (chapter) => ApiClient.instance.contentText(chapter.itemId),
      ),
    );
  }

  /// Book reviews for the work being listened to.
  ///
  /// Named for what it shows rather than the official page's 章评 label: the
  /// backend has no chapter-comment endpoint (see the 书评 action above).
  Future<void> _showBookReviews() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _AudioCommentsSheet(
        bookId: _bookId,
        loader: widget.sourceLoader != null || widget.playerFactory != null
            ? null
            : ApiClient.instance.bookComments,
      ),
    );
  }

  /// Sleep timer: pauses playback when the countdown elapses.
  Future<void> _showSleepTimer() async {
    final palette = HomePalette.of(context);
    // -1 is the explicit 关闭定时 choice; a null result means the sheet was
    // dismissed and must leave any active timer untouched.
    const options = <int>[-1, 15, 30, 60];
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('定时关闭')),
            for (final minutes in options)
              ListTile(
                title: Text(minutes == -1 ? '关闭定时' : '$minutes 分钟后'),
                trailing: (_sleepMinutes ?? -1) == minutes
                    ? const Icon(LucideIcons.check, color: HomePalette.accent)
                    : null,
                onTap: () => Navigator.pop(context, minutes),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    _applySleepTimer(selected == -1 ? null : selected);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(selected == -1 ? '已关闭定时' : '将在 $selected 分钟后停止播放'),
        duration: const Duration(seconds: 2),
      ),
    );
    if (!mounted) return;
    // Keep the palette referenced so the sheet inherits the theme colours.
    assert(palette.canvas != palette.surface);
  }

  void _applySleepTimer(int? minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (minutes == null) {
      _sleepTimerTick?.cancel();
      setState(() => _sleepRemaining = null);
      _publishMoreState();
      return;
    }
    setState(() => _sleepRemaining = Duration(minutes: minutes));
    _publishMoreState();
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _sleepTimer = null;
      _sleepTimerTick?.cancel();
      if (!mounted) return;
      setState(() {
        _sleepRemaining = null;
        _wantPlay = false;
      });
      _publishMoreState();
      final player = _player;
      if (player != null && player.isCreated) {
        unawaited(_pause(player, _generation));
      }
    });
    _startSleepTicker();
  }

  Timer? _sleepTimerTick;

  void _startSleepTicker() {
    _sleepTimerTick?.cancel();
    _sleepTimerTick = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = _sleepRemaining;
      if (remaining == null || !mounted) return;
      final next = remaining - const Duration(seconds: 1);
      setState(() => _sleepRemaining = next > Duration.zero ? next : null);
      _publishMoreState();
      if (next <= Duration.zero) _sleepTimerTick?.cancel();
    });
  }

  int? get _sleepMinutes {
    final remaining = _sleepRemaining;
    if (remaining == null) return null;
    final minutes = (remaining.inSeconds / 60).ceil();
    return minutes >= 60 ? 60 : (minutes >= 30 ? 30 : 15);
  }

  Future<void> _showMore() async {
    _publishMoreState();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => ValueListenableBuilder<_MoreSnapshot>(
        valueListenable: _moreState,
        builder: (context, snapshot, _) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(LucideIcons.alarm_clock),
                title: const Text('定时关闭'),
                subtitle: Text(
                  snapshot.sleepMinutes == null
                      ? '未开启'
                      : '剩余 ${snapshot.sleepMinutes} 分钟',
                ),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_showSleepTimer());
                },
              ),
              ListTile(
                leading: const Icon(LucideIcons.list),
                title: const Text('目录'),
                subtitle: Text('共 ${_chapters.length} 章'),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_showCatalog());
                },
              ),
              SwitchListTile.adaptive(
                key: const ValueKey('audio-auto-next'),
                contentPadding: EdgeInsets.zero,
                title: const Text('自动下一章'),
                value: snapshot.autoAdvance,
                onChanged: snapshot.loading
                    ? null
                    : (enabled) {
                        if (!mounted || _loading) return;
                        setState(() => _autoAdvance = enabled);
                        _publishMoreState();
                        unawaited(_persistProgress());
                      },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the audio book a 真人讲书 row names.
  ///
  /// Such a row carries an `abook_id`, i.e. a *different book* — one per
  /// narrator version — not a voice. playinfo ignores an abook_id sent as a
  /// `tone_id` (NO_THIS_TONE even with the exact int64), while
  /// `book_id = abook_id` with that book's own chapter plays it.
  Future<void> _switchNarrator(AudioTone tone) => _switchBookVersion(
    tone.id,
    title: tone.title,
    cover: _cover,
    toneId: '0',
  );

  /// Stop playback before a route can open another native player. The restored
  /// route stays paused at its own position until the user explicitly plays.
  /// Note: .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md
  Future<_RoutePlayback?> _suspendForRoute(int generation) async {
    await _persistProgress();
    if (!_current(generation)) return null;
    final snapshot = (
      index: _index,
      position: _player?.position ?? _position.value,
      completed: _completed,
      autoplay: _wantPlay,
    );
    setState(() => _wantPlay = false);
    _publishListeningSession(playing: false);
    final suspendedGeneration = ++_generation;
    ++_seekGeneration;
    _saveTimer?.cancel();
    _listenTime.stop();
    await _releasePlayer();
    return _current(suspendedGeneration) ? snapshot : null;
  }

  Future<void> _restoreAfterRoute(_RoutePlayback? snapshot) async {
    if (!mounted || snapshot == null) return;
    await _openChapter(
      snapshot.index,
      position: snapshot.position,
      autoplay: false,
      completed: snapshot.completed,
    );
  }

  /// Note: Cross-book TTS choices and exact IDs — see
  /// .agents/notes/implemented/bug-fix/2026-09-16-linked-audio-voices.md.
  /// Note: 真人讲书切智能朗读在同一听书页完成 — 见
  /// .agents/notes/implemented/bug-fix/2026-09-18-audio-voice-switch-flash.md
  Future<void> _switchBookVersion(
    String targetId, {
    required String title,
    required String cover,
    required String toneId,
    BuildContext? replaceContext,
  }) async {
    if (_switchingVersion || targetId.isEmpty || targetId == _bookId) {
      return;
    }
    final generation = _generation;
    setState(() => _switchingVersion = true);
    try {
      final chapters = await (widget.directoryLoader ?? _defaultDirectory)(
        targetId,
      ).timeout(const Duration(seconds: 20));
      if (!_current(generation)) return;
      if (chapters.isEmpty) {
        throw const FormatException('所选声音版本暂无目录');
      }
      final start = _narratorChapterIndex(chapters);
      final autoplay = _wantPlay;
      if (replaceContext != null && replaceContext.mounted) {
        Navigator.pop(replaceContext);
      }
      await _persistProgress();
      if (!_current(generation)) return;
      ++_generation;
      ++_seekGeneration;
      _saveTimer?.cancel();
      _listenTime.stop();
      await _releasePlayer();
      if (!mounted) return;
      setState(() {
        _bookId = targetId;
        _title = title;
        _cover = cover;
        _chapters = List<Chapter>.unmodifiable(chapters);
        _index = start;
        _toneId = toneId;
        _extras = const AudioExtras();
        _excerpt = '';
        _error = null;
        _position.value = Duration.zero;
        _duration = Duration.zero;
        _subtitles = SubtitleTrack.empty;
      });
      _settingsReady = _prepareSettings(forceToneId: toneId);
      await _openChapter(
        start,
        restoreHistory: true,
        toneId: toneId,
        autoplay: autoplay,
        persistCurrent: false,
      );
    } catch (_) {
      if (replaceContext != null && replaceContext.mounted) {
        Navigator.pop(replaceContext);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂时无法切换声音，请稍后重试')));
    } finally {
      if (mounted) setState(() => _switchingVersion = false);
    }
  }

  /// `/api/directory` answers per volume, and the listening page wants one
  /// flat chapter list.
  Future<List<Chapter>> _defaultDirectory(String bookId) async {
    final volumes = await ApiClient.instance.directoryChapters(
      bookId,
      tab: '听书',
    );
    return [for (final volume in volumes) ...volume];
  }

  /// Index in [chapters] holding the same content as the chapter playing here.
  ///
  /// The two versions number the same text their own way (`第一章合着…` vs
  /// `001 合着…`), so the ordinal prefix is stripped before comparing; a
  /// version whose titles do not line up falls back to the same position.
  int _narratorChapterIndex(List<Chapter> chapters) {
    final want = _chapterCore(_chapters[_index].title);
    if (want.isNotEmpty) {
      for (var i = 0; i < chapters.length; i++) {
        if (_chapterCore(chapters[i].title) == want) return i;
      }
    }
    // Some versions drop the chapter title and only number the installments
    // (`麻衣风水师01` for `第1章 八鬼抬轿`), often with an extra teaser in
    // front (`麻衣风水师00片花`). A positional fallback would land on the
    // teaser there, so match the ordinal number first.
    final ordinal = _chapterOrdinal(_chapters[_index].title);
    if (ordinal != null) {
      for (var i = 0; i < chapters.length; i++) {
        if (_chapterOrdinal(chapters[i].title) == ordinal) return i;
      }
    }
    return _index < chapters.length ? _index : 0;
  }

  /// First number a chapter title carries: `第1章 …`, `001 …` and
  /// `麻衣风水师01` all yield `1`; a title without any number yields `null`.
  static int? _chapterOrdinal(String title) {
    final match = RegExp(r'\d+').firstMatch(title);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  /// `第一章合着，我是出生头子！？` / `001 合着，我是出生头子！？`
  /// both reduce to `合着，我是出生头子！？`.
  static String _chapterCore(String title) => title
      .trim()
      .replaceFirst(
        RegExp(
          r'^(?:第\s*[0-9零一二三四五六七八九十百千]+\s*[章节集回话]?|\d+)'
          r'\s*[、.，,：:·\-]?\s*',
        ),
        '',
      )
      .trim();

  /// A voice row either switches the playing voice or opens another audio
  /// book, depending on the family it belongs to.
  void _onToneSelected(AudioTone tone) {
    if (_narratorTones.any((narrator) => narrator.id == tone.id)) {
      unawaited(_switchNarrator(tone));
      return;
    }
    unawaited(_selectTone(tone.id));
  }

  Future<void> _openRelated(RelatedWork work) async {
    if (work.id.isEmpty || _switchingVersion) return;
    final generation = _generation;
    _RoutePlayback? suspended;
    setState(() => _switchingVersion = true);
    try {
      suspended = await _suspendForRoute(generation);
      if (!mounted || suspended == null) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => DetailPage(
            item: MediaItem(
              id: work.id,
              title: work.title,
              cover: work.cover,
              author: '',
              badge: work.label,
              ep: '',
              kind: work.kind == 'video' ? 'video' : 'book',
            ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂时无法打开作品，请稍后重试')));
    } finally {
      await _restoreAfterRoute(suspended);
      if (mounted) setState(() => _switchingVersion = false);
    }
  }
}

/// Reviews sheet opened from the 书评 action.
class _AudioCommentsSheet extends StatefulWidget {
  final String bookId;
  final Future<BookCommentPage> Function(String bookId, {int offset})? loader;

  const _AudioCommentsSheet({required this.bookId, this.loader});

  @override
  State<_AudioCommentsSheet> createState() => _AudioCommentsSheetState();
}

class _AudioCommentsSheetState extends State<_AudioCommentsSheet> {
  BookCommentPage? _page;
  List<BookComment> _comments = const [];
  bool _failed = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _nextOffset = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final loader = widget.loader;
    if (loader == null) {
      setState(() => _failed = true);
      return;
    }
    try {
      final page = await loader(widget.bookId);
      if (mounted) {
        setState(() {
          _page = page;
          _comments = page.comments;
          _hasMore = page.hasMore;
          _nextOffset = page.nextOffset;
        });
      }
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _loadMore() async {
    final loader = widget.loader;
    if (loader == null || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await loader(widget.bookId, offset: _nextOffset);
      if (!mounted) return;
      setState(() {
        _comments = [..._comments, ...page.comments];
        _hasMore = page.hasMore;
        _nextOffset = page.nextOffset;
        _loadingMore = false;
      });
    } on Exception {
      // The appended list stays; the footer flips back so it can be retried.
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final page = _page;
    final hasMore = _hasMore && widget.loader != null;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Row(
              children: [
                Text(
                  page?.headerLabel ?? '书评',
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (page != null && page.scoreLabel.isNotEmpty)
                  Text(
                    page.scoreLabel,
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _failed
                ? Center(
                    child: Text(
                      '暂时无法加载书评',
                      style: TextStyle(color: palette.muted),
                    ),
                  )
                : page == null
                ? const Center(
                    child: CircularProgressIndicator(color: HomePalette.accent),
                  )
                : _comments.isEmpty
                ? Center(
                    child: Text(
                      '还没有书评',
                      style: TextStyle(color: palette.muted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _comments.length + (hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _comments.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: _loadingMore
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: HomePalette.accent,
                                    ),
                                  )
                                : TextButton(
                                    key: const Key('audio_comments_more'),
                                    onPressed: _loadMore,
                                    child: Text(
                                      '加载更多书评',
                                      style: TextStyle(
                                        color: palette.accentText,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                          ),
                        );
                      }
                      final comment = _comments[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    comment.userName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: palette.ink,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  comment.relativeTime(),
                                  style: TextStyle(
                                    color: palette.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              comment.text,
                              style: TextStyle(
                                color: palette.ink,
                                fontSize: 13,
                                height: 1.65,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Compact icon + tooltip button used in the transport row.
class _TransportButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  const _TransportButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      style: IconButton.styleFrom(
        foregroundColor: active ? palette.accentText : palette.ink,
        disabledForegroundColor: palette.line,
        minimumSize: const Size(48, 48),
      ),
      icon: Icon(icon, size: 22),
    );
  }
}

class _AudioCatalog extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentIndex;

  const _AudioCatalog({required this.chapters, required this.currentIndex});

  @override
  State<_AudioCatalog> createState() => _AudioCatalogState();
}

class _AudioCatalogState extends State<_AudioCatalog> {
  late final _controller = ScrollController(
    initialScrollOffset: widget.currentIndex * 72.0,
  );
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final indexes = [
      for (var index = 0; index < widget.chapters.length; index++)
        if (_query.isEmpty ||
            widget.chapters[index].title.toLowerCase().contains(_query) ||
            '${index + 1}' == _query)
          index,
    ];
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SizedBox(
          height: (MediaQuery.sizeOf(context).height - keyboard) * 0.72,
          child: Column(
            children: [
              Text(
                '目录 · ${widget.chapters.length} 章',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: '搜索章节名称或序号',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) {
                    setState(() => _query = value.trim().toLowerCase());
                    if (_controller.hasClients) _controller.jumpTo(0);
                  },
                ),
              ),
              Expanded(
                child: indexes.isEmpty
                    ? const Center(child: Text('没有匹配的章节'))
                    : ListView.builder(
                        controller: _controller,
                        itemCount: indexes.length,
                        itemExtent: 72,
                        itemBuilder: (context, offset) {
                          final index = indexes[offset];
                          final chapter = widget.chapters[index];
                          return ListTile(
                            key: ValueKey('audio-chapter-$index'),
                            selected: index == widget.currentIndex,
                            leading: Text('${index + 1}'),
                            title: Text(
                              chapter.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: chapter.volumeName.isEmpty
                                ? null
                                : Text(
                                    chapter.volumeName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            trailing: index == widget.currentIndex
                                ? const Icon(Icons.graphic_eq)
                                : null,
                            onTap: () => Navigator.pop(context, index),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
