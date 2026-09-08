import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/chapter_media.dart';
import '../models/media_item.dart';
import '../services/api_client.dart';
import '../services/audio_history.dart';
import '../services/library_store.dart';
import '../services/native_player.dart';

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
  });

  @override
  State<AudioPage> createState() => _AudioPageState();
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
  double _rate = 1;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _seekPreview;
  List<AudioVoice> _voices = const [_defaultVoice];

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
    setState(() {
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
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_generation;
    ++_seekGeneration;
    _saveTimer?.cancel();
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
      _wantPlay = autoplay && _appActive;
    });
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
      final wasCompleted = sameChapter && saved?['completed'] == true;
      final itemId = widget.chapters[index].itemId;
      final source =
          await (widget.sourceLoader?.call(itemId, toneId: _toneId) ??
                  ApiClient.instance.audioSource(
                    itemId,
                    bookId: widget.bookId,
                    toneId: _toneId,
                  ))
              .timeout(const Duration(seconds: 30));
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

  static Duration _savedDuration(Object? value) {
    if (value is! num || !value.isFinite || value <= 0) return Duration.zero;
    final milliseconds = value * 1000;
    if (!milliseconds.isFinite || milliseconds >= 0x7fffffffffffffff) {
      return Duration.zero;
    }
    return Duration(milliseconds: milliseconds.round());
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
    final voice = await showModalBottomSheet<AudioVoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('选择音色')),
            for (final voice in _voices)
              ListTile(
                title: Text(voice.label),
                trailing: voice.id == _toneId ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, voice),
              ),
          ],
        ),
      ),
    );
    if (!mounted || voice == null || voice.id == _toneId) return;
    await _openChapter(
      _index,
      position: _player?.position ?? _position,
      toneId: voice.id,
      autoplay: _wantPlay,
    );
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

  static String _timeLabel(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 0x7fffffff);
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('听书'),
        actions: [
          IconButton(
            tooltip: '目录',
            onPressed: widget.chapters.isEmpty ? null : _showCatalog,
            icon: const Icon(Icons.format_list_bulleted_rounded),
          ),
        ],
      ),
      body: widget.chapters.isEmpty
          ? const Center(child: Text('暂无可播放章节'))
          : SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                        child: Column(
                          children: [
                            _cover(
                              (constraints.maxHeight * 0.30).clamp(120, 240),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              widget.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              widget.chapters[_index].title,
                              key: const ValueKey('audio-chapter-title'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '第 ${_index + 1} / ${widget.chapters.length} 章',
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 18),
                            _status(),
                            const SizedBox(height: 12),
                            _seekBar(),
                            const SizedBox(height: 8),
                            _controls(),
                            const SizedBox(height: 18),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 16,
                              children: [
                                TextButton.icon(
                                  key: const ValueKey('audio-speed'),
                                  onPressed: _ready ? _showRates : null,
                                  icon: const Icon(Icons.speed_rounded),
                                  label: Text('倍速 · ${_rateLabel(_rate)}×'),
                                ),
                                TextButton.icon(
                                  key: const ValueKey('audio-voice'),
                                  onPressed: _ready && _voices.length > 1
                                      ? _showVoices
                                      : null,
                                  icon: const Icon(Icons.record_voice_over),
                                  label: Text(
                                    _voices
                                        .firstWhere(
                                          (voice) => voice.id == _toneId,
                                          orElse: () => _defaultVoice,
                                        )
                                        .label,
                                  ),
                                ),
                              ],
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
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _cover(double size) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.primaryContainer,
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          size: 72,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: widget.cover.isEmpty
            ? placeholder
            : CachedNetworkImage(
                imageUrl: widget.cover,
                fit: BoxFit.cover,
                memCacheWidth: 600,
                placeholder: (context, url) => placeholder,
                errorWidget: (context, url, error) => placeholder,
              ),
      ),
    );
  }

  Widget _status() {
    if (_error case final message?) {
      return Column(
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('audio-retry'),
            onPressed: () => _openChapter(_index, restoreHistory: true),
            icon: const Icon(Icons.refresh),
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
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(_loading ? '正在加载音频…' : '缓冲中…'),
        ],
      );
    }
    return Text(_completed ? '本章已播完' : (_wantPlay ? '正在播放' : '已暂停'));
  }

  Widget _seekBar() {
    final maximum = _duration.inMilliseconds.toDouble();
    final value = (_seekPreview ?? _position.inMilliseconds.toDouble()).clamp(
      0.0,
      maximum > 0 ? maximum : 1.0,
    );
    return Column(
      children: [
        Slider(
          key: const ValueKey('audio-seek'),
          value: value,
          max: maximum > 0 ? maximum : 1,
          label: _timeLabel(Duration(milliseconds: value.round())),
          onChanged: _ready && maximum > 0
              ? (value) => setState(() => _seekPreview = value)
              : null,
          onChangeEnd: _ready && maximum > 0
              ? (value) => _seekTo(Duration(milliseconds: value.round()))
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _timeLabel(Duration(milliseconds: value.round())),
                key: const ValueKey('audio-position'),
              ),
              Text(_timeLabel(_duration)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _controls() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      IconButton(
        tooltip: '上一章',
        onPressed: _index > 0 ? () => _openChapter(_index - 1) : null,
        icon: const Icon(Icons.skip_previous_rounded),
      ),
      _AudioSkipButton(
        forward: false,
        onPressed: _ready
            ? () => _seekTo(_position - const Duration(seconds: 15))
            : null,
      ),
      IconButton.filled(
        tooltip: _wantPlay && !_completed ? '暂停' : '播放',
        onPressed: _ready ? _togglePlayback : null,
        padding: const EdgeInsets.all(18),
        iconSize: 38,
        icon: Icon(
          _wantPlay && !_completed ? Icons.pause_rounded : Icons.play_arrow,
        ),
      ),
      _AudioSkipButton(
        forward: true,
        onPressed: _ready
            ? () => _seekTo(_position + const Duration(seconds: 15))
            : null,
      ),
      IconButton(
        tooltip: '下一章',
        onPressed: _index + 1 < widget.chapters.length
            ? () => _openChapter(_index + 1)
            : null,
        icon: const Icon(Icons.skip_next_rounded),
      ),
    ],
  );
}

class _AudioSkipButton extends StatelessWidget {
  final bool forward;
  final VoidCallback? onPressed;

  const _AudioSkipButton({required this.forward, this.onPressed});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: forward ? '前进15秒' : '后退15秒',
    onPressed: onPressed,
    icon: SizedBox.square(
      dimension: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.flip(
            flipX: forward,
            child: const Icon(Icons.replay_rounded, size: 32),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('15', style: TextStyle(fontSize: 9)),
          ),
        ],
      ),
    ),
  );
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
