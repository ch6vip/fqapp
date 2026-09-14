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

  const AudioPage({
    super.key,
    required this.bookId,
    required this.title,
    required this.chapters,
    this.startIndex = 0,
    this.cover = '',
    this.historyStore,
    this.playerFactory,
    this.sourceLoader,
    this.voicesLoader,
    this.extrasLoader,
    this.subtitleLoader,
    this.excerptLoader,
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

  late int _index;
  late final AudioHistory _history;
  late final Future<void> _settingsReady;
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
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _seekPreview;
  List<AudioVoice> _voices = const [_defaultVoice];
  AudioExtras _extras = const AudioExtras();
  SubtitleTrack _subtitles = SubtitleTrack.empty;
  Timer? _sleepTimer;
  Duration? _sleepRemaining;
  bool _inShelf = false;

  /// Resolves the listening-page decorations. See [AudioExtras].
  Future<AudioExtras> _loadExtras() {
    final loader = widget.extrasLoader;
    if (loader != null) return loader(widget.bookId);
    if (widget.sourceLoader != null ||
        widget.voicesLoader != null ||
        widget.playerFactory != null) {
      return Future.value(const AudioExtras());
    }
    return _defaultAudioExtras(widget.bookId);
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
    _history = AudioHistory(widget.historyStore ?? LibraryStore.instance);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _index = widget.chapters.isEmpty
        ? 0
        : widget.startIndex.clamp(0, widget.chapters.length - 1);
    _settingsReady = _prepareSettings();
    if (widget.chapters.isEmpty) {
      _loading = false;
    } else {
      unawaited(_openChapter(_index, restoreHistory: true));
    }
  }

  Future<void> _prepareSettings() async {
    final history = _history.load(widget.bookId).catchError((Object _) => null);
    final voices = () async {
      try {
        return await (widget.voicesLoader?.call() ??
                ApiClient.instance.audioVoices(widget.bookId))
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        return <AudioVoice>[_defaultVoice];
      }
    }();
    final extras = _loadExtrasSafely();
    final saved = await history;
    final available = await voices;
    if (!mounted) return;
    final byId = <String, AudioVoice>{'0': _defaultVoice};
    for (final voice in available) {
      if (voice.id.trim().isNotEmpty && voice.label.trim().isNotEmpty) {
        byId[voice.id] = voice;
      }
    }
    final savedTone = saved?['toneId'];
    final savedRate = saved?['rate'];
    // Only a saved voice that the decorations endpoint knows is worth waiting
    // for before the first source request. Letting /tones, /related or /detail
    // gate playback for everyone else is the p09 defect; the wait is bounded
    // so a slow or hung decorations call can never block playback forever.
    AudioExtras? resolved;
    if (savedTone is String &&
        savedTone.trim().isNotEmpty &&
        !byId.containsKey(savedTone)) {
      try {
        resolved = await extras.timeout(const Duration(seconds: 3));
      } catch (_) {
        resolved = null;
      }
      if (!mounted) return;
      if (resolved != null) _mergeToneVoices(resolved, byId);
    }
    setState(() {
      if (resolved != null) _extras = resolved;
      _voices = List.unmodifiable(byId.values);
      if (savedTone is String && byId.containsKey(savedTone)) {
        _toneId = savedTone;
      }
      if (savedRate is num &&
          savedRate.isFinite &&
          _rates.contains(savedRate.toDouble())) {
        _rate = savedRate.toDouble();
      }
      if (saved?['autoAdvance'] case final bool enabled) {
        _autoAdvance = enabled;
      }
      if (saved?['inShelf'] case final bool shelf) {
        _inShelf = shelf;
      }
    });
    // Publish decorations whenever they arrive (including after the bounded
    // wait above) without touching the tone already chosen for playback.
    unawaited(_publishExtras(extras));
  }

  Future<AudioExtras> _loadExtrasSafely() async {
    try {
      return await _loadExtras().timeout(const Duration(seconds: 10));
    } catch (_) {
      return const AudioExtras();
    }
  }

  /// Upstream can offer several voices under the same display name (for
  /// example two different ids both titled 智能朗读). Give every duplicate a
  /// stable qualifier so the tone cards and the voice picker never show two
  /// identical rows.
  List<AudioTone> _uniqueTones(List<AudioTone> tones) {
    final counts = <String, int>{};
    for (final tone in tones) {
      final title = tone.title.trim();
      if (title.isNotEmpty) counts[title] = (counts[title] ?? 0) + 1;
    }
    final used = <String>{};
    final out = <AudioTone>[];
    for (final tone in tones) {
      final title = tone.title.trim();
      if (title.isEmpty) {
        out.add(tone);
        continue;
      }
      var label = title;
      if ((counts[title] ?? 0) > 1) {
        final qualifier = tone.description.trim();
        label = qualifier.isEmpty
            ? '$title（${tone.id}）'
            : '$title · $qualifier';
      }
      if (!used.add(label)) {
        label = '$title（${tone.id}）';
        var bump = 2;
        while (!used.add(label)) {
          label = '$title（${tone.id}·${bump++})';
        }
      }
      out.add(_renamedTone(tone, label));
    }
    return out;
  }

  static AudioTone _renamedTone(AudioTone tone, String title) => AudioTone(
    id: tone.id,
    title: title,
    description: tone.description,
    badge: tone.badge,
    iconUrl: tone.iconUrl,
    isMultiTone: tone.isMultiTone,
    gender: tone.gender,
  );

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

  Future<void> _publishExtras(Future<AudioExtras> extras) async {
    AudioExtras loaded;
    try {
      loaded = await extras;
    } catch (_) {
      loaded = const AudioExtras();
    }
    if (!mounted) return;
    final byId = <String, AudioVoice>{
      for (final voice in _voices) voice.id: voice,
    };
    _mergeToneVoices(loaded, byId);
    setState(() {
      _extras = loaded;
      _voices = List.unmodifiable(byId.values);
    });
  }

  @override
  void dispose() {
    ListeningSession.instance.clear();
    WidgetsBinding.instance.removeObserver(this);
    ++_generation;
    ++_seekGeneration;
    _saveTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepTimerTick?.cancel();
    _listenTime.stop();
    unawaited(_persistProgress());
    unawaited(_releasePlayer());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (!_appActive) {
      _wantPlay = false;
      _listenTime.stop();
      // Capture first, so a platform pause failure cannot lose the position.
      unawaited(_persistProgress());
      final player = _player;
      if (player != null && player.isCreated) {
        unawaited(_pause(player, _generation));
      }
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
  }) async {
    if (!mounted || index < 0 || index >= widget.chapters.length) return;
    final generation = ++_generation;
    ++_seekGeneration;
    _saveTimer?.cancel();
    _listenTime.stop();
    unawaited(_persistProgress());
    final released = _releasePlayer();
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _completed = false;
      _position = position ?? Duration.zero;
      _duration = Duration.zero;
      _seekPreview = null;
      _subtitles = SubtitleTrack.empty;
      _wantPlay = autoplay && _appActive;
    });
    unawaited(_loadExcerpt(widget.chapters[index].itemId));
    NativePlayer? candidate;
    try {
      await _settingsReady;
      if (!_current(generation)) return;
      if (toneId != null) _toneId = toneId;
      Map<String, dynamic>? saved;
      if (restoreHistory) {
        try {
          saved = await _history.load(widget.bookId);
        } catch (_) {
          // Listening can still start when local storage is unavailable.
        }
      }
      if (!_current(generation)) return;
      final sameChapter =
          resumeAudioChapterIndex(saved, widget.chapters) == index;
      final resume =
          position ??
          (sameChapter ? _savedDuration(saved?['position']) : Duration.zero);
      final savedDuration = sameChapter
          ? _savedDuration(saved?['duration'])
          : Duration.zero;
      final wasCompleted =
          completed ?? (sameChapter && saved?['completed'] == true);
      final itemId = widget.chapters[index].itemId;
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
      await player.create(source.url, '');
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
        _position = _boundedPosition(player.position, duration);
        _completed = wasCompleted;
        if (wasCompleted) _wantPlay = false;
        _loading = false;
      });
      // Subtitles are decoration: they arrive whenever the book has generated
      // speech text and are ignored otherwise.
      unawaited(_refreshSubtitles(generation, itemId, source.toneId));
      if (_wantPlay && _appActive) await _play(player, generation);
      if (!_current(generation, player)) return;
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
  Future<AudioSource> _loadSourceWithRetry(String itemId) {
    final loader = widget.sourceLoader;
    if (loader != null) {
      return loader(
        itemId,
        toneId: _toneId,
      ).timeout(const Duration(seconds: 30));
    }
    return retryTransient(
      () => ApiClient.instance
          .audioSource(itemId, bookId: widget.bookId, toneId: _toneId)
          .timeout(const Duration(seconds: 30)),
    );
  }

  /// Loads the 边听边读 track for a chapter and publishes it if the chapter is
  /// still the active one.
  Future<void> _refreshSubtitles(
    int generation,
    String itemId,
    String toneId,
  ) async {
    final track = await _loadSubtitles(itemId, toneId);
    if (!_current(generation) || track.isEmpty) return;
    setState(() => _subtitles = track);
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
    if (_index < 0 || _index >= widget.chapters.length) return;
    final chapter = widget.chapters[_index];
    ListeningSession.instance.update(
      bookId: widget.bookId,
      chapterId: chapter.itemId,
      chapterTitle: chapter.title,
      position: _boundedPosition(_player?.position ?? _position, _duration),
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
        setState(() => _position = _boundedPosition(position, _duration));
        // Publish the REAL playing state: a paused seek also fires this
        // stream, and publishing playing=true would yank the reader back to
        // the narrated page while paused.
        _publishListeningSession(playing: player.playing);
      }),
      player.durationStream.listen((duration) {
        if (!_current(generation, player) || duration <= Duration.zero) return;
        setState(() {
          _duration = duration;
          _position = _boundedPosition(_position, duration);
        });
      }),
      player.playingStream.listen((playing) {
        if (!_current(generation, player)) return;
        // Creation acknowledges prepare(), and API duration can be known
        // before the CDN is readable. Keep the last successful chapter until
        // this candidate actually starts foreground playback.
        if (playing &&
            !_hasPlayed &&
            _activeIndex == _index &&
            _appActive &&
            _wantPlay) {
          _hasPlayed = true;
          unawaited(_persistProgress());
        }
        _syncListenClock();
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
        final shouldAdvance = _wantPlay && _appActive && _autoAdvance;
        setState(() {
          _completed = true;
          _wantPlay = false;
          _position = _boundedPosition(player.position, _duration);
        });
        _listenTime.stop();
        unawaited(_persistProgress());
        if (shouldAdvance && _index + 1 < widget.chapters.length) {
          unawaited(_openChapter(_index + 1));
        } else {
          unawaited(_pause(player, generation));
        }
        _publishListeningSession();
      }),
      player.errorStream.listen((error) => _fail(error, generation)),
    ]);
  }

  void _syncListenClock() {
    final player = _player;
    if (_appActive &&
        _wantPlay &&
        !_completed &&
        !_loading &&
        _error == null &&
        player != null &&
        player.playing &&
        !player.buffering) {
      _listenTime.start();
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
      'id': widget.bookId,
      'bookId': widget.bookId,
      'kind': 'audio',
      'title': widget.title,
      'cover': widget.cover,
      'chapterId': widget.chapters[index].itemId,
      'episodeId': widget.chapters[index].itemId,
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
    ListeningSession.instance.clear();
    if (!_current(generation)) return;
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
  }

  Future<void> _play(NativePlayer player, int generation) async {
    if (!_current(generation, player) || !_appActive || !_wantPlay) return;
    await player.play();
    if (!_current(generation, player)) return;
    // A play acknowledgement can arrive after the app was backgrounded.
    if (!_appActive || !_wantPlay) await player.pause();
    if (!_current(generation, player)) return;
    _syncListenClock();
    setState(() {});
  }

  Future<void> _pause(NativePlayer player, int generation) async {
    _publishListeningSession(playing: false);
    try {
      await player.pause();
      if (_current(generation, player)) await _persistProgress();
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    if (!_ready || player == null || !_appActive) return;
    final generation = _generation;
    if (_wantPlay) {
      setState(() => _wantPlay = false);
      _listenTime.stop();
      await _pause(player, generation);
      return;
    }
    // A replay seek must remain cancellable by backgrounding or pausing.
    setState(() => _wantPlay = true);
    try {
      if (_completed) {
        await player.seek(Duration.zero);
        if (!_current(generation, player)) return;
        setState(() {
          _position = Duration.zero;
          _completed = false;
        });
      }
      await _play(player, generation);
      if (_current(generation, player)) await _persistProgress();
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
    setState(() => _seekPreview = target.inMilliseconds.toDouble());
    try {
      await player.seek(target);
      if (!_current(generation, player) || seekGeneration != _seekGeneration) {
        return;
      }
      setState(() {
        _seekPreview = null;
        _position = target;
        _completed = false;
      });
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
    final selected = await showModalBottomSheet<VoiceOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: VoiceSettingsSheet(
          selectedId: _toneId,
          narrators: _narratorOptions(),
          online: _onlineOptions(),
          offline: _offlineOptions(),
          onSelect: (option) => Navigator.pop(context, option),
          onDownload: _downloadOfflineTone,
        ),
      ),
    );
    if (!mounted || selected == null || selected.id == _toneId) return;
    await _openChapter(
      _index,
      position: _player?.position ?? _position,
      toneId: selected.id,
      autoplay: _wantPlay,
      completed: _completed,
    );
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

  /// 智能朗读 grid: the backend tones, then any voice the CSV loader knows that
  /// the tone endpoint did not cover. The default voice stays selectable so a
  /// listener can always step back to it.
  List<VoiceOption> _onlineOptions() {
    final tones = _uniqueTones(_extras.tones.ttsTones);
    final ids = <String>{'0'};
    final narratorIds = {
      for (final tone in _extras.tones.narratorTones) tone.id,
    };
    final options = <VoiceOption>[];
    for (final tone in tones) {
      if (!ids.add(tone.id)) continue;
      options.add(
        VoiceOption(
          id: tone.id,
          title: tone.title,
          description: tone.description,
          badge: tone.badge,
          isMultiTone: tone.isMultiTone,
        ),
      );
    }
    for (final voice in _voices) {
      if (voice.id == '0' ||
          narratorIds.contains(voice.id) ||
          !ids.add(voice.id)) {
        continue;
      }
      options.add(VoiceOption(id: voice.id, title: voice.label));
    }
    // A hearing-native album has no 智能朗读 voices at all; only offer the
    // default fallback when there is another voice to switch away from.
    if (options.isNotEmpty) {
      options.insert(0, const VoiceOption(id: '0', title: '默认音色'));
    }
    return options;
  }

  List<VoiceOption> _offlineOptions() => [
    for (final tone in _uniqueTones(_extras.tones.offlineTones))
      VoiceOption(
        id: tone.id,
        title: tone.title,
        description: tone.description,
        badge: tone.badge,
        offline: true,
      ),
  ];

  void _downloadOfflineTone(VoiceOption option) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('离线音色「${option.title}」需在官方客户端下载')));
  }

  Future<void> _showCatalog() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) =>
          _AudioCatalog(chapters: widget.chapters, currentIndex: _index),
    );
    if (!mounted || selected == null || selected == _index) return;
    await _openChapter(selected);
  }

  static String _rateLabel(double rate) =>
      rate == rate.roundToDouble() ? rate.toInt().toString() : rate.toString();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (widget.chapters.isEmpty) {
      return Scaffold(
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
    final chapter = widget.chapters[_index];
    final tones = _mode == 'narrator' ? _narratorTones : _ttsTones;
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        child: Column(
          children: [
            AudioTopBar(
              mode: _mode,
              narratorAvailable: _narratorTones.isNotEmpty,
              onCollapse: () => Navigator.maybePop(context),
              onMore: _showMore,
              onInspire: _showMore,
              onSelectMode: _selectMode,
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
                            cover: widget.cover,
                            bookTitle: widget.title,
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
                          child: AudioProgressRow(
                            position: _position,
                            duration: _duration,
                            preview: _seekPreview,
                            enabled: _ready,
                            onChanged: (value) =>
                                setState(() => _seekPreview = value),
                            onChangeEnd: (value) =>
                                _seekTo(Duration(milliseconds: value.round())),
                            onBack15: _ready
                                ? () => _seekTo(
                                    _position - const Duration(seconds: 15),
                                  )
                                : null,
                            onForward15: _ready
                                ? () => _seekTo(
                                    _position + const Duration(seconds: 15),
                                  )
                                : null,
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
                            selectedId: _toneId,
                            currentChapterTitle: chapter.title,
                            onSelect: (tone) => _selectTone(tone.id),
                            onReadAlong: _showReadAlong,
                            onShowVoices: _showVoices,
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

  List<AudioTone> get _ttsTones => _extras.tones.ttsTones;
  List<AudioTone> get _narratorTones => _extras.tones.narratorTones;

  /// Current family, derived from the selected tone so the top tabs always
  /// describe what is actually playing: `tts` (智能朗读) or `narrator` (真人讲书).
  String get _mode =>
      _narratorTones.any((tone) => tone.id == _toneId) ? 'narrator' : 'tts';

  /// Official top tabs: switching the mode selects the first voice of that
  /// family, which flips [_mode].
  void _selectMode(String mode) {
    if (mode == _mode) return;
    final tones = mode == 'narrator' ? _narratorTones : _ttsTones;
    if (tones.isEmpty) return;
    if (!tones.any((tone) => tone.id == _toneId)) {
      _selectTone(tones.first.id);
    }
  }

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
        final summary = await ApiClient.instance.chapterSummaries(
          widget.bookId,
          [itemId],
        );
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
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: _subtitles.isEmpty
              ? Center(
                  child: Text(
                    '本章暂无同步字幕',
                    style: TextStyle(color: palette.muted, fontSize: 13),
                  ),
                )
              : AudioSubtitleView(
                  track: _subtitles,
                  position: _seekPreview == null
                      ? _position
                      : Duration(milliseconds: _seekPreview!.round()),
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
          onTap: _index + 1 < widget.chapters.length
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

  void _selectTone(String toneId) {
    if (toneId == _toneId) return;
    unawaited(
      _openChapter(
        _index,
        position: _player?.position ?? _position,
        toneId: toneId,
        autoplay: _wantPlay,
        completed: _completed,
      ),
    );
  }

  Future<void> _toggleShelf() async {
    final next = !_inShelf;
    setState(() => _inShelf = next);
    // The shelf flag is independent of playback, so it is written even when
    // nothing has been played yet in this session.
    try {
      final existing =
          await _history.load(widget.bookId) ?? const <String, dynamic>{};
      await _history.save({
        ...existing,
        'id': widget.bookId,
        'bookId': widget.bookId,
        'kind': 'audio',
        'title': widget.title,
        'cover': widget.cover,
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
      id: widget.bookId,
      title: widget.title,
      cover: widget.cover,
      chapters: widget.chapters,
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
        bookId: widget.bookId,
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
      return;
    }
    setState(() => _sleepRemaining = Duration(minutes: minutes));
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _sleepTimer = null;
      _sleepTimerTick?.cancel();
      if (!mounted) return;
      setState(() {
        _sleepRemaining = null;
        _wantPlay = false;
      });
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
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.alarm_clock),
              title: const Text('定时关闭'),
              subtitle: Text(
                _sleepRemaining == null
                    ? '未开启'
                    : '剩余 ${_sleepRemaining!.inMinutes} 分钟',
              ),
              onTap: () {
                Navigator.pop(context);
                unawaited(_showSleepTimer());
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.list),
              title: const Text('目录'),
              subtitle: Text('共 ${widget.chapters.length} 章'),
              onTap: () {
                Navigator.pop(context);
                unawaited(_showCatalog());
              },
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('audio-auto-next'),
              contentPadding: EdgeInsets.zero,
              title: const Text('自动下一章'),
              value: _autoAdvance,
              onChanged: _loading
                  ? null
                  : (enabled) {
                      setState(() => _autoAdvance = enabled);
                      unawaited(_persistProgress());
                    },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _openRelated(RelatedWork work) async {
    if (work.id.isEmpty) return;
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
  }
}

/// Reviews sheet opened from the 书评 action.
class _AudioCommentsSheet extends StatefulWidget {
  final String bookId;
  final Future<BookCommentPage> Function(String bookId)? loader;

  const _AudioCommentsSheet({required this.bookId, this.loader});

  @override
  State<_AudioCommentsSheet> createState() => _AudioCommentsSheetState();
}

class _AudioCommentsSheetState extends State<_AudioCommentsSheet> {
  BookCommentPage? _page;
  bool _failed = false;

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
      if (mounted) setState(() => _page = page);
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final page = _page;
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
                : page.comments.isEmpty
                ? Center(
                    child: Text(
                      '还没有书评',
                      style: TextStyle(color: palette.muted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: page.comments.length,
                    itemBuilder: (context, index) {
                      final comment = page.comments[index];
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
