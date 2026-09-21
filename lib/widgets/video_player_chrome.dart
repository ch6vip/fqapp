import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_item.dart';
import '../services/native_player.dart';
import '../services/playback_format.dart';
import '../services/player_preferences.dart';
import 'player/player_cover.dart';
import 'player/player_video_layout.dart';
import 'player/story_player_panel.dart';
import 'player/story_seek_bar.dart';

class VideoPlayerChrome extends StatefulWidget {
  final NativePlayer? player;
  final String title;
  final List<Chapter> episodes;
  final int currentIndex;
  final int? playingIndex;
  final Duration duration;
  final bool playing;
  final bool autoAdvance;
  final ValueChanged<bool>? onAutoAdvanceChanged;
  final bool enabled;
  final Widget child;
  final String coverUrl;
  final String description;
  final bool descriptionLoading;
  final String? descriptionError;
  final VoidCallback? onRequestDescription;
  final VoidCallback? onRetryDescription;
  final ValueChanged<bool>? onPagingChanged;
  final Future<void> Function(int) onSelectEpisode;
  final void Function(Object) onError;

  const VideoPlayerChrome({
    super.key,
    required this.player,
    this.title = '',
    required this.episodes,
    required this.currentIndex,
    this.playingIndex,
    required this.duration,
    required this.playing,
    this.autoAdvance = true,
    this.onAutoAdvanceChanged,
    this.enabled = true,
    required this.child,
    this.coverUrl = '',
    this.description = '',
    this.descriptionLoading = false,
    this.descriptionError,
    this.onRequestDescription,
    this.onRetryDescription,
    this.onPagingChanged,
    required this.onSelectEpisode,
    required this.onError,
  });

  @override
  State<VideoPlayerChrome> createState() => _VideoPlayerChromeState();
}

class _VideoPlayerChromeState extends State<VideoPlayerChrome>
    with WidgetsBindingObserver {
  late final PageController _pages;
  final _panel = DraggableScrollableController();
  final _panelExtent = ValueNotifier<double>(0);
  final _panelExpanded = ValueNotifier<bool>(false);
  final _position = ValueNotifier<Duration>(Duration.zero);
  final _seekValue = ValueNotifier<double?>(null);

  /// Latest target of a relative +/-10s seek whose native call has not settled
  /// yet; back-to-back taps accumulate onto it instead of reusing the last
  /// acknowledged position.
  Duration? _pendingSeek;
  late final _timeline = Listenable.merge([_position, _seekValue]);
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playWhenReadySubscription;
  Timer? _hideTimer;
  bool _visible = true;
  bool _seeking = false;
  bool _resumeAfterSeek = false;
  bool _modalOpen = false;
  bool _panelOpen = false;
  bool _panelAnimating = false;
  bool _panelWasVisible = false;
  bool _panelHeaderDragging = false;
  bool _fullScreen = false;
  bool _locked = false;
  bool _boosting = false;
  bool _paging = false;
  bool _appActive = true;
  bool _resumeOnForeground = false;
  int _panelTab = 1;
  int _panelAnimation = 0;
  int _interaction = 0;
  double _panelRestFraction = .55;
  double _panelMaxFraction = .55;
  List<double> _panelSnapSizes = const [.55];
  double _rate = 1;
  int _rateGeneration = 0;
  Future<void> _systemUiUpdates = Future<void>.value();
  bool _systemUiTouched = false;

  /// The orientation list currently pinned while fullscreen, so an unchanged
  /// answer does not re-issue a rotation request.
  List<DeviceOrientation>? _appliedOrientations;

  /// The video size [appliedOrientations] was decided from. The player mutates
  /// its own size when the media loads, so comparing widget generations would
  /// read the new value on both sides and never notice the change.
  Size _appliedVideoSize = Size.zero;

  double get _panelFraction => _panelExtent.value;
  double get _progressValue {
    final durationMs = math.max(0, widget.duration.inMilliseconds);
    return _seekValue.value ??
        (durationMs > 0
            ? _position.value.inMilliseconds.clamp(0, durationMs) / durationMs
            : 0.0);
  }

  bool get _ready => widget.enabled && (widget.player?.isCreated ?? false);
  bool get _playbackRequested =>
      widget.playing ||
      ((widget.player?.playWhenReady ?? false) &&
          !(widget.player?.completed ?? false));
  Size get _videoSize => Size(
    (widget.player?.videoWidth ?? 9).toDouble(),
    (widget.player?.videoHeight ?? 16).toDouble(),
  );
  String get _episodeTitle => widget.episodes.isEmpty
      ? '暂无剧集'
      : widget.episodes[widget.currentIndex].title;
  String get _seriesTitle =>
      widget.title.isEmpty ? _episodeTitle : widget.title;

  @override
  void initState() {
    super.initState();
    _pages = PageController(initialPage: widget.currentIndex);
    _panel.addListener(_panelChanged);
    _listenToPosition();
    WidgetsBinding.instance.addObserver(this);
    _appActive =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    unawaited(_loadRate());
    _scheduleHide();
  }

  @override
  void didUpdateWidget(VideoPlayerChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) _listenToPosition();
    if (oldWidget.player != widget.player ||
        oldWidget.enabled && !widget.enabled) {
      if (_boosting && oldWidget.player != null) {
        unawaited(oldWidget.player!.setRate(_rate).catchError((Object _) {}));
      }
      ++_interaction;
      _seeking = false;
      _seekValue.value = null;
      _resumeAfterSeek = false;
      _resumeOnForeground = false;
      _boosting = false;
    }
    if (_ready && (oldWidget.player != widget.player || !oldWidget.enabled)) {
      unawaited(_control((player) => player.setRate(_rate)));
      // A locked screen keeps the orientation the viewer settled on, so an
      // episode change must not rotate it either.
      if (_fullScreen && !_locked) unawaited(_applySystemUi());
    }
    if (oldWidget.currentIndex != widget.currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pages.hasClients) return;
        if ((_pages.page ?? 0).round() != widget.currentIndex) {
          _pages.jumpToPage(widget.currentIndex);
        }
      });
    }
    // The video size arrives a moment after a player is created, so this is
    // where a fullscreen episode learns whether it is landscape. The check is
    // size-based because the player mutates its own size in place.
    _adoptVideoOrientation();
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.playing != widget.playing ||
        oldWidget.player != widget.player) {
      if ((!widget.playing && !_seeking) || !widget.enabled) _visible = true;
      _scheduleHide();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _pages.dispose();
    _panel.dispose();
    _panelExtent.dispose();
    _panelExpanded.dispose();
    unawaited(_positionSubscription?.cancel());
    unawaited(_playWhenReadySubscription?.cancel());
    _position.dispose();
    _seekValue.dispose();
    if (_boosting && widget.player != null) {
      unawaited(widget.player!.setRate(_rate).catchError((Object _) {}));
    }
    if (_systemUiTouched) {
      unawaited(_systemUiUpdates.then((_) => _restoreSystemUi()));
    }
    super.dispose();
  }

  void _listenToPosition() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_playWhenReadySubscription?.cancel());
    final player = widget.player;
    _pendingSeek = null;
    _position.value = player?.position ?? Duration.zero;
    // The native 200ms ticks belong to the timeline only. In particular, they
    // must not rebuild the episode pager, description or the video texture.
    _positionSubscription = player?.positionStream.listen((position) {
      if (mounted && identical(widget.player, player)) {
        _position.value = position;
      }
    });
    _playWhenReadySubscription = player?.playWhenReadyStream.listen((_) {
      if (mounted && identical(widget.player, player)) setState(() {});
    });
  }

  Future<void> _loadRate() async {
    final generation = _rateGeneration;
    try {
      final rate = await PlayerPreferences.loadPlaybackRate();
      if (!mounted || generation != _rateGeneration) return;
      setState(() => _rate = rate);
      await _control((player) => player.setRate(_boosting ? 2 : rate));
    } catch (_) {}
  }

  Future<void> _control(Future<void> Function(NativePlayer) operation) async {
    final player = widget.player;
    if (player == null || !_ready) return;
    try {
      await operation(player);
    } catch (error) {
      if (mounted && widget.player == player && _ready) widget.onError(error);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (!active && _appActive) {
      _appActive = false;
      ++_interaction;
      _resumeOnForeground =
          _ready && (_playbackRequested || (_seeking && _resumeAfterSeek));
      _cancelSeek(resume: false);
      _endBoost();
      _hideTimer?.cancel();
      unawaited(_control((player) => player.pause()));
    } else if (active && !_appActive) {
      _appActive = true;
      if (_resumeOnForeground) unawaited(_control((player) => player.play()));
      _resumeOnForeground = false;
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_ready ||
        !_appActive ||
        !widget.playing ||
        _seeking ||
        _modalOpen ||
        _panelOpen ||
        _boosting ||
        _paging) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _toggleControls() {
    if (_panelOpen || _modalOpen || _seeking || _boosting || _paging) return;
    setState(() => _visible = !_visible);
    if (_visible) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _togglePlayback() {
    if (!_ready ||
        !_appActive ||
        _locked ||
        _panelOpen ||
        _modalOpen ||
        _seeking ||
        _paging) {
      return;
    }
    _endBoost();
    final interaction = ++_interaction;
    final pause = _playbackRequested;
    unawaited(
      _control((player) async {
        if (pause) {
          await player.pause();
        } else {
          if (player.completed) await player.seek(Duration.zero);
          if (!mounted ||
              widget.player != player ||
              interaction != _interaction ||
              !_appActive ||
              _locked ||
              !_ready) {
            return;
          }
          await player.play();
        }
      }),
    );
    setState(() => _visible = true);
    _scheduleHide();
  }

  void _startSeek(double value) {
    if (!_ready || _locked) return;
    _endBoost();
    ++_interaction;
    _hideTimer?.cancel();
    _resumeAfterSeek = _playbackRequested;
    setState(() {
      _seeking = true;
      _seekValue.value = value;
    });
    unawaited(_control((player) => player.pause()));
  }

  Future<void> _finishSeek(double value) async {
    final player = widget.player;
    if (player == null || !_seeking) return;
    final interaction = _interaction;
    final target = Duration(
      milliseconds: (widget.duration.inMilliseconds * value.clamp(0.0, 1.0))
          .round(),
    );
    try {
      await player.seek(target);
      if (!mounted || widget.player != player || interaction != _interaction) {
        return;
      }
      if (_resumeAfterSeek && _appActive && _ready) await player.play();
    } catch (error) {
      if (mounted && widget.player == player && interaction == _interaction) {
        widget.onError(error);
      }
    } finally {
      if (mounted && widget.player == player && interaction == _interaction) {
        setState(() {
          _seeking = false;
          _seekValue.value = null;
        });
        _scheduleHide();
      }
    }
  }

  void _cancelSeek({bool resume = true}) {
    if (!_seeking) return;
    ++_interaction;
    final shouldResume = resume && _resumeAfterSeek && _appActive;
    setState(() {
      _seeking = false;
      _seekValue.value = null;
    });
    if (shouldResume) unawaited(_control((player) => player.play()));
    _scheduleHide();
  }

  void _seekBy(int seconds) {
    if (_locked) return;
    final base = _pendingSeek ?? _position.value;
    final milliseconds = (base.inMilliseconds + seconds * 1000).clamp(
      0,
      math.max(0, widget.duration.inMilliseconds),
    );
    final target = Duration(milliseconds: milliseconds.toInt());
    // Remember the optimistic target before awaiting the native seek so the
    // next relative tap accumulates on top of it.
    _pendingSeek = target;
    unawaited(
      _control((player) async {
        try {
          await player.seek(target);
        } finally {
          if (identical(widget.player, player) && _pendingSeek == target) {
            _pendingSeek = null;
          }
        }
      }),
    );
    _scheduleHide();
  }

  void _startBoost() {
    if (!_ready ||
        _locked ||
        !widget.playing ||
        _seeking ||
        _paging ||
        _panelOpen ||
        _modalOpen) {
      return;
    }
    _hideTimer?.cancel();
    setState(() => _boosting = true);
    unawaited(_control((player) => player.setRate(2)));
  }

  void _endBoost() {
    if (!_boosting) return;
    setState(() => _boosting = false);
    unawaited(_control((player) => player.setRate(_rate)));
    _scheduleHide();
  }

  Future<void> _showRates({bool includePlaybackSettings = false}) async {
    if (_locked || _modalOpen) return;
    _endBoost();
    _cancelSeek();
    _hideTimer?.cancel();
    setState(() => _modalOpen = true);
    var autoAdvance = widget.autoAdvance;
    final selected = await showModalBottomSheet<double>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, updateSheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  includePlaybackSettings ? '播放设置' : '播放速度',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (includePlaybackSettings) ...[
                  SwitchListTile(
                    key: const ValueKey('player-auto-advance'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动连播'),
                    subtitle: Text(autoAdvance ? '播完自动播放下一集' : '本集播完停止'),
                    value: autoAdvance,
                    onChanged: widget.onAutoAdvanceChanged == null
                        ? null
                        : (enabled) {
                            updateSheet(() => autoAdvance = enabled);
                            widget.onAutoAdvanceChanged!(enabled);
                          },
                  ),
                  const SizedBox(height: 8),
                  const Text('播放速度'),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    for (final rate in PlayerPreferences.playbackRates)
                      ChoiceChip(
                        label: Text('${_rateLabel(rate)}×'),
                        selected: rate == _rate,
                        onSelected: (_) => Navigator.pop(context, rate),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _modalOpen = false);
    if (selected != null) {
      final generation = ++_rateGeneration;
      setState(() => _rate = selected);
      try {
        // Persist in selection order. A slow reply to an older native rate
        // change must not save that value after the user's newer selection.
        await Future.wait<void>([
          PlayerPreferences.savePlaybackRate(selected),
          _control((player) => player.setRate(selected)),
        ]);
      } catch (_) {
        if (mounted && generation == _rateGeneration) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('倍速已生效，但未能保存设置')));
        }
      }
    }
    if (mounted) _scheduleHide();
  }

  void _openPanel(int tab) {
    if (_locked) return;
    _endBoost();
    _cancelSeek();
    _hideTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _panelTab = tab;
      _panelRestFraction = PlayerVideoLayout.panelFractionFor(_videoSize);
      _panelMaxFraction = _panelRestFraction;
      // Keep this list stable while the panel follows a drag. Replacing it
      // makes DraggableScrollableSheet start a new snap on every rebuild.
      _panelSnapSizes = [_panelRestFraction];
      _panelOpen = true;
      _panelWasVisible = false;
      _panelHeaderDragging = false;
    });
    widget.onRequestDescription?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _panelOpen) unawaited(_animatePanel(_panelRestFraction));
    });
  }

  void _panelChanged() {
    if (!mounted || !_panel.isAttached) return;
    _panelExtent.value = _panel.size;
    _panelExpanded.value = _panelFraction > .9;
    if (_panelFraction > .01) _panelWasVisible = true;
    if (_panelFraction <= .001 && _panelWasVisible && !_panelAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _panelFraction <= .001 && !_panelAnimating) {
          _removePanel();
        }
      });
    }
  }

  Future<void> _animatePanel(double target) async {
    if (!_panel.isAttached) return;
    final animation = ++_panelAnimation;
    _panelAnimating = true;
    if (target > _panelMaxFraction) {
      setState(() => _panelMaxFraction = 1);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || animation != _panelAnimation || !_panel.isAttached) {
        return;
      }
    }
    await _panel.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    if (!mounted || animation != _panelAnimation) return;
    _panelAnimating = false;
    if (target == 0) {
      _removePanel();
    } else if (target == _panelRestFraction) {
      setState(() => _panelMaxFraction = _panelRestFraction);
    }
  }

  bool _onPanelScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      // A body drag can cancel the controller's animation future. Invalidate
      // its completion so a later drag-to-close can still remove the panel.
      ++_panelAnimation;
      _panelAnimating = false;
    } else if (notification is ScrollEndNotification) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_panelOpen ||
            _panelAnimating ||
            _panelHeaderDragging) {
          return;
        }
        if ((_panelFraction - _panelRestFraction).abs() < .001 &&
            _panelMaxFraction != _panelRestFraction) {
          setState(() => _panelMaxFraction = _panelRestFraction);
        }
      });
    }
    return false;
  }

  void _removePanel() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _panelOpen = false;
      _panelExtent.value = 0;
      _panelExpanded.value = false;
      _panelWasVisible = false;
      _panelHeaderDragging = false;
      _visible = true;
    });
    _scheduleHide();
  }

  void _startPanelDrag(DragStartDetails details) {
    ++_panelAnimation;
    _panelAnimating = false;
    _panelHeaderDragging = true;
    // Like the reference's drag area, only the header unlocks expansion above
    // the resting height. Scrolling the body keeps the video visible.
    setState(() => _panelMaxFraction = 1);
  }

  void _dragPanel(DragUpdateDetails details, double height) {
    if (!_panel.isAttached || height <= 0) return;
    ++_panelAnimation;
    _panelAnimating = false;
    _panel.jumpTo((_panel.size - details.delta.dy / height).clamp(0.0, 1.0));
  }

  void _endPanelDrag(DragEndDetails details) {
    if (!_panelHeaderDragging) return;
    _panelHeaderDragging = false;
    final velocity = details.primaryVelocity ?? 0;
    final size = _panelFraction;
    final rest = _panelRestFraction;
    final target = velocity > 600
        ? (size > rest + .1 ? rest : 0.0)
        : velocity < -600
        ? (size < rest - .1 ? rest : 1.0)
        : size < rest / 2
        ? 0.0
        : size < (rest + 1) / 2
        ? rest
        : 1.0;
    unawaited(_animatePanel(target));
  }

  Future<void> _selectEpisode(int index) async {
    if (_locked ||
        index < 0 ||
        index >= widget.episodes.length ||
        index == widget.currentIndex) {
      return;
    }
    _endBoost();
    _cancelSeek(resume: false);
    await widget.onSelectEpisode(index);
    if (mounted) _scheduleHide();
  }

  Future<void> _back() async {
    if (_locked) {
      _setLocked(false);
    } else if (_panelOpen) {
      await _animatePanel(0);
    } else if (_fullScreen) {
      await _toggleFullScreen();
    } else {
      await Navigator.maybePop(context);
    }
  }

  Future<void> _toggleFullScreen() async {
    if (_locked) return;
    _endBoost();
    _cancelSeek();
    setState(() => _fullScreen = !_fullScreen);
    await _applySystemUi();
    if (mounted) _scheduleHide();
  }

  void _setLocked(bool locked) {
    _endBoost();
    _cancelSeek();
    ++_interaction;
    setState(() {
      _locked = locked;
      _visible = true;
    });
    // A locked screen means the viewer has settled on an orientation, so
    // unlocking is when the video gets to claim it.
    if (!locked) _adoptVideoOrientation();
    _scheduleHide();
  }

  Future<void> _applySystemUi() async {
    _systemUiTouched = true;
    final fullScreen = _fullScreen;
    final operation = _systemUiUpdates.then((_) async {
      if (!mounted || _fullScreen != fullScreen) return;
      if (fullScreen) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        final orientations = _orientationsForVideo;
        // A freshly created player reports no video size, so the orientation is
        // unknown rather than portrait. Deciding "0 > 0 is false, therefore
        // portrait" is what snapped landscape playback back to portrait every
        // time the next episode auto-played. With no answer, leave the device in
        // the orientation the viewer already chose; [_adoptVideoOrientation]
        // applies the real one once the size arrives.
        _appliedOrientations = orientations;
        _appliedVideoSize = _playerVideoSize;
        if (orientations == null) return;
        await SystemChrome.setPreferredOrientations(orientations);
      } else {
        _appliedOrientations = null;
        _appliedVideoSize = Size.zero;
        await _restoreSystemUi();
      }
    });
    _systemUiUpdates = operation.catchError((Object _) {});
    await _systemUiUpdates;
  }

  /// The player's reported video size; 0x0 until the media has loaded.
  Size get _playerVideoSize => Size(
    (widget.player?.videoWidth ?? 0).toDouble(),
    (widget.player?.videoHeight ?? 0).toDouble(),
  );

  /// The orientations fullscreen should use, or null while the video size is
  /// still unknown (a new player starts at 0x0).
  ///
  /// Note: 未知尺寸不得判成竖屏，否则连播会把横屏掰回竖屏 — 见
  /// .agents/notes/implemented/bug-fix/2026-09-11-player-orientation-on-auto-advance.md
  List<DeviceOrientation>? get _orientationsForVideo {
    final size = _playerVideoSize;
    if (size.width <= 0 || size.height <= 0) return null;
    return size.width > size.height
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown];
  }

  /// Applies the video's orientation once its size is known.
  ///
  /// Called from [didUpdateWidget], which runs on the rebuild the size event
  /// triggers. Without it a fullscreen episode would keep whatever orientation
  /// was in effect while its size was still unknown.
  void _adoptVideoOrientation() {
    if (!_fullScreen || _locked) return;
    final orientations = _orientationsForVideo;
    if (orientations == null) return;
    if (_playerVideoSize == _appliedVideoSize &&
        listEquals(orientations, _appliedOrientations)) {
      return;
    }
    unawaited(_applySystemUi());
  }

  Future<void> _restoreSystemUi() async {
    try {
      await SystemChrome.setPreferredOrientations([]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_locked && !_panelOpen && !_fullScreen,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && (_locked || _panelOpen || _fullScreen)) unawaited(_back());
    },
    child: Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final insets = MediaQuery.paddingOf(context);
          final window = constraints.biggest;
          final landscape = _fullScreen && window.width > window.height;
          final layout = PlayerVideoLayout.calculate(
            window: window,
            insets: insets,
            videoSize: _videoSize,
            fit: VideoFit.contain,
            panelFraction: _panelFraction,
            restingPanelFraction: _panelRestFraction,
            fullScreen: _fullScreen,
          );
          final durationMs = math.max(0, widget.duration.inMilliseconds);
          final unobstructed = !_panelOpen && !_modalOpen;
          final controls = _visible && unobstructed && !_seeking && !_locked;
          final canPage =
              unobstructed && !_locked && !_seeking && !_boosting && !landscape;
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                key: const ValueKey('video-surface'),
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onDoubleTap: _togglePlayback,
                onLongPressStart: (_) => _startBoost(),
                onLongPressEnd: (_) => _endBoost(),
                onLongPressCancel: _endBoost,
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.depth != 0) return false;
                    if (notification is ScrollStartNotification) {
                      _paging = true;
                      _hideTimer?.cancel();
                      widget.onPagingChanged?.call(true);
                    } else if (notification is ScrollEndNotification) {
                      _paging = false;
                      widget.onPagingChanged?.call(false);
                      _scheduleHide();
                    }
                    return false;
                  },
                  child: PageView.builder(
                    key: const ValueKey('episode-pager'),
                    controller: _pages,
                    scrollDirection: Axis.vertical,
                    physics: canPage
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    itemCount: math.max(1, widget.episodes.length),
                    onPageChanged: (index) => unawaited(_selectEpisode(index)),
                    itemBuilder: (context, index) => Stack(
                      key: ValueKey('episode-page-$index'),
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Colors.black),
                        if (index == widget.currentIndex)
                          _positionVideo(
                            window: window,
                            insets: insets,
                            fitVideo: _ready,
                            child: SizedBox(
                              key: const ValueKey('video-frame'),
                              child: widget.child,
                            ),
                          )
                        else
                          _positionVideo(
                            window: window,
                            insets: insets,
                            child: PlayerCover(
                              url: widget.coverUrl,
                              label: widget.episodes[index].title,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (controls) ...[
                _topBar(insets),
                if (!landscape) _rightBar(insets),
                if (!landscape) _information(insets),
                if (_ready) _transport(insets, landscape),
              ],
              if ((_visible || _seeking) && unobstructed && _ready && !_locked)
                Positioned(
                  // Controls leave this Stack while seeking. Keep the outer
                  // layer keyed so the active drag recognizer survives that
                  // sibling change until the finger is released.
                  key: const ValueKey('video-seek-layer'),
                  left: insets.left + 12,
                  right: insets.right + 12,
                  bottom: insets.bottom + 61,
                  child: RepaintBoundary(
                    child: ListenableBuilder(
                      listenable: _timeline,
                      builder: (context, child) => StorySeekBar(
                        key: const ValueKey('video-seek'),
                        value: _progressValue,
                        enabled: durationMs > 0,
                        seeking: _seeking,
                        onStart: _startSeek,
                        onChanged: (value) => _seekValue.value = value,
                        onEnd: (value) => unawaited(_finishSeek(value)),
                        onCancel: _cancelSeek,
                      ),
                    ),
                  ),
                ),
              if (_ready &&
                  !_playbackRequested &&
                  !_locked &&
                  unobstructed &&
                  _visible &&
                  !_seeking)
                Positioned.fromRect(
                  rect: layout.viewport,
                  child: IgnorePointer(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.play_arrow_rounded,
                              size: 86,
                              color: Colors.white.withValues(alpha: .2),
                            ),
                            const SizedBox(height: 12),
                            ValueListenableBuilder<Duration>(
                              valueListenable: _position,
                              builder: (context, position, child) => Text(
                                '${_time(position)} / ${_time(widget.duration)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_seeking)
                Center(
                  child: IgnorePointer(
                    child: ListenableBuilder(
                      listenable: _timeline,
                      builder: (context, child) => Text(
                        '${_time(Duration(milliseconds: (durationMs * _progressValue).round()))} / ${_time(widget.duration)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          shadows: [Shadow(blurRadius: 8)],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_boosting)
                Positioned(
                  top: insets.top + 56,
                  left: 0,
                  right: 0,
                  child: const Center(
                    child: IgnorePointer(child: Chip(label: Text('2× 加速中'))),
                  ),
                ),
              if (_locked) ...[
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('player-lock-shield'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleControls,
                  ),
                ),
                if (_visible)
                  Positioned(
                    left: insets.left + 12,
                    top: window.height / 2 - 24,
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('player-unlock'),
                      onPressed: () => _setLocked(false),
                      icon: const Icon(Icons.lock_open_rounded),
                      label: const Text('解锁'),
                    ),
                  ),
              ],
              if (_panelOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('story-panel-scrim'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => unawaited(_animatePanel(0)),
                  ),
                ),
                Positioned(
                  top: insets.top,
                  left: insets.left,
                  right: insets.right,
                  bottom: 0,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onPanelScroll,
                    child: DraggableScrollableSheet(
                      controller: _panel,
                      initialChildSize: 0,
                      minChildSize: 0,
                      maxChildSize: _panelMaxFraction,
                      snap: true,
                      snapSizes: _panelSnapSizes,
                      shouldCloseOnMinExtent: false,
                      builder: (context, scroll) =>
                          ValueListenableBuilder<bool>(
                            valueListenable: _panelExpanded,
                            builder: (context, expanded, child) =>
                                StoryPlayerPanel(
                                  scrollController: scroll,
                                  episodes: widget.episodes,
                                  currentIndex: widget.currentIndex,
                                  playingIndex:
                                      widget.playingIndex ??
                                      (_ready ? widget.currentIndex : null),
                                  title: _seriesTitle,
                                  description: widget.description,
                                  descriptionLoading: widget.descriptionLoading,
                                  descriptionError: widget.descriptionError,
                                  onRetryDescription: widget.onRetryDescription,
                                  initialTab: _panelTab,
                                  expanded: expanded,
                                  playing: widget.playing,
                                  onTabChanged: (tab) => _panelTab = tab,
                                  onSelectEpisode: (index) {
                                    unawaited(_animatePanel(0));
                                    unawaited(_selectEpisode(index));
                                  },
                                  onDragStart: _startPanelDrag,
                                  onDragUpdate: (details) => _dragPanel(
                                    details,
                                    layout.availableHeight,
                                  ),
                                  onDragEnd: _endPanelDrag,
                                  onDragCancel: () =>
                                      _endPanelDrag(DragEndDetails()),
                                  onExpand: () => unawaited(
                                    _animatePanel(
                                      _panelFraction > .9
                                          ? _panelRestFraction
                                          : 1,
                                    ),
                                  ),
                                  onClose: () => unawaited(_animatePanel(0)),
                                ),
                          ),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    ),
  );

  Widget _positionVideo({
    required Size window,
    required EdgeInsets insets,
    required Widget child,
    bool fitVideo = false,
  }) => ValueListenableBuilder<double>(
    valueListenable: _panelExtent,
    child: child,
    builder: (context, fraction, child) {
      final layout = PlayerVideoLayout.calculate(
        window: window,
        insets: insets,
        videoSize: _videoSize,
        fit: VideoFit.contain,
        panelFraction: fraction,
        restingPanelFraction: _panelRestFraction,
        fullScreen: _fullScreen,
      );
      // Retain the video/cover subtree while only its rectangle follows the
      // panel. DraggableScrollableSheet already retains its own content.
      return Positioned.fromRect(
        rect: fitVideo ? layout.video : layout.viewport,
        child: child!,
      );
    },
  );

  Widget _topBar(EdgeInsets insets) => Positioned(
    left: insets.left,
    right: insets.right,
    top: 0,
    child: Container(
      padding: EdgeInsets.only(top: insets.top),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              onPressed: _back,
              icon: const Icon(
                Icons.arrow_back_ios_new,
                color: Colors.white,
                size: 22,
              ),
            ),
            Expanded(
              child: Text(
                _seriesTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            IconButton(
              tooltip: '锁定播放',
              onPressed: () => _setLocked(true),
              icon: const Icon(Icons.lock_outline_rounded, color: Colors.white),
            ),
            IconButton(
              tooltip: '播放设置',
              onPressed: () => _showRates(includePlaybackSettings: true),
              icon: const Icon(Icons.more_vert, color: Colors.white),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _rightBar(EdgeInsets insets) {
    final scale = MediaQuery.textScalerOf(context);
    final width = math.min(84.0, math.max(56.0, scale.scale(28) + 24));
    final height = math.max(
      58.0,
      math.max(30.0, scale.scale(21) * 1.2) + scale.scale(12) * 1.2 + 8,
    );
    Widget action(
      String label,
      String tooltip,
      Widget icon,
      VoidCallback onTap,
    ) => SizedBox(
      width: width,
      height: height,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  height: 1.2,
                  shadows: [Shadow(color: Colors.black, blurRadius: 5)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Positioned(
      right: insets.right + 4,
      bottom: insets.bottom + 163,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          action(
            '选集',
            '选集',
            const Icon(
              Icons.playlist_play_rounded,
              color: Colors.white,
              size: 30,
            ),
            () => _openPanel(1),
          ),
          const SizedBox(height: 10),
          action(
            '倍速',
            '倍速 ${_rateLabel(_rate)}×',
            Text(
              '${_rateLabel(_rate)}×',
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                height: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            _showRates,
          ),
          const SizedBox(height: 10),
          action(
            '清屏',
            '清屏',
            const Icon(Icons.crop_free_rounded, color: Colors.white, size: 27),
            _toggleControls,
          ),
        ],
      ),
    );
  }

  Widget _information(EdgeInsets insets) => Positioned(
    left: insets.left,
    right: insets.right,
    bottom: insets.bottom + 91,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black54],
        ),
      ),
      child: InkWell(
        key: const ValueKey('story-description-entry'),
        onTap: () => _openPanel(0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.episodes.isEmpty
                        ? '暂无剧集'
                        : '第 ${widget.currentIndex + 1} 集 · 共 ${widget.episodes.length} 集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _episodeTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              '简介',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const Icon(
              Icons.keyboard_arrow_down,
              color: Colors.white70,
              size: 18,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _transport(EdgeInsets insets, bool landscape) => Positioned(
    left: insets.left + 8,
    right: insets.right + 8,
    bottom: insets.bottom,
    child: SizedBox(
      key: const ValueKey('video-controls'),
      height: 61,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _transportButton(
            '上一集',
            Icons.skip_previous_rounded,
            widget.currentIndex > 0
                ? () => _selectEpisode(widget.currentIndex - 1)
                : null,
          ),
          _transportButton(
            '快退10秒',
            Icons.replay_10,
            widget.duration > Duration.zero ? () => _seekBy(-10) : null,
          ),
          _transportButton(
            _playbackRequested ? '暂停' : '播放',
            _playbackRequested ? Icons.pause_rounded : Icons.play_arrow_rounded,
            _togglePlayback,
          ),
          _transportButton(
            '快进10秒',
            Icons.forward_10,
            widget.duration > Duration.zero ? () => _seekBy(10) : null,
          ),
          _transportButton(
            '下一集',
            Icons.skip_next_rounded,
            widget.currentIndex < widget.episodes.length - 1
                ? () => _selectEpisode(widget.currentIndex + 1)
                : null,
          ),
          if (landscape) ...[
            TextButton(
              onPressed: _showRates,
              child: Text(
                '${_rateLabel(_rate)}×',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            TextButton(
              onPressed: () => _openPanel(1),
              child: const Text('选集', style: TextStyle(color: Colors.white)),
            ),
          ],
          _transportButton(
            _fullScreen ? '退出全屏' : '全屏',
            _fullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
            _toggleFullScreen,
          ),
        ],
      ),
    ),
  );

  Widget _transportButton(
    String tooltip,
    IconData icon,
    VoidCallback? onPressed,
  ) => SizedBox(
    width: 40,
    height: 48,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      color: Colors.white,
      disabledColor: Colors.white24,
      icon: Icon(icon, size: 25),
    ),
  );
}

// Both formatters are shared with the audio page (services/playback_format.dart)
// so the two players can never drift apart again.
String _rateLabel(double rate) => formatPlaybackRate(rate);

String _time(Duration value) => formatPlaybackTime(value);
