part of '../../pages/audio_page.dart';

/// The last-listened book offered by the idle capsule after a cold start.
class RecentListen {
  const RecentListen({
    required this.bookId,
    required this.title,
    required this.cover,
    required this.progress,
    required this.request,
  });

  final String bookId;
  final String title;
  final String cover;

  /// Whole-book listened fraction, 0..1.
  final double progress;

  /// Builds the listening request; loading the directory may fail.
  final Future<AudioPage> Function() request;
}

typedef RecentListenLoader = Future<RecentListen?> Function();

/// Official cold start (`recentread/j0.java` `m0`): when the newest reading
/// record is a listen-type book, the home shell shows the idle capsule with
/// its saved progress. Returns null otherwise.
Future<RecentListen?> loadRecentListen() async {
  final history = await LibraryStore.instance.history();
  if (history.isEmpty) return null;
  final entry = history.first;
  if (entry['kind'] != 'audio') return null;
  final bookId = historyContentId(entry);
  if (bookId.isEmpty) return null;
  final chapter = (entry['progress'] as num?)?.toDouble() ?? 0;
  final episode = (entry['episode'] as num?)?.toDouble() ?? 0;
  final count = (entry['chapterCount'] as num?)?.toDouble() ?? 0;
  final progress = count > 0 ? (episode + chapter) / count : chapter;
  final title = entry['title']?.toString() ?? '';
  final cover = entry['cover']?.toString() ?? '';
  return RecentListen(
    bookId: bookId,
    title: title,
    cover: cover,
    progress: progress.isFinite ? progress.clamp(0.0, 1.0) : 0,
    request: () async {
      final volumes = await ApiClient.instance.directoryChapters(
        bookId,
        tab: '听书',
      );
      final chapters = [for (final volume in volumes) ...volume];
      if (chapters.isEmpty) throw const FormatException('暂无听书目录');
      return AudioPage(
        bookId: bookId,
        title: title,
        cover: cover,
        chapters: chapters,
        startIndex: resumeAudioChapterIndex(entry, chapters) ?? 0,
      );
    },
  );
}

/// Owns one listening session for the lifetime of the app's Navigator.
class AudioPlaybackScope extends StatefulWidget {
  const AudioPlaybackScope({
    super.key,
    required this.navigatorKey,
    required this.child,
    this.recentListen,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  /// Supplies the cold-start idle capsule. Null disables it.
  final RecentListenLoader? recentListen;

  static Future<void> startSystemTts(BuildContext context, SystemTtsBook book) {
    final owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
    if (owner == null) throw StateError('当前阅读入口不支持持续朗读');
    return owner.startSystemTts(book);
  }

  /// 把正在进行的朗读跳到 [position]（阅读页双击跳读用）。
  ///
  /// 只有智能朗读 / 真人讲书这类走播放器的会话能被跳转；系统朗读（本地 TTS）
  /// 没有可 seek 的音频流，返回 false 让调用方提示。
  static bool seekActive(BuildContext context, Duration position) {
    final owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
    return owner?.seekActive(position) ?? false;
  }

  /// 阅读页那枚「暂停播放 / 继续播放」胶囊：切换这本书的播放状态。
  ///
  /// 对应官方 `ReaderPlayerButton`（`ajo.xml` 的 `TextView j53`）。没有正在
  /// 控制这本书的会话时返回 false；音频与系统 TTS 都路由到各自的控制器。
  static bool togglePlayback(BuildContext context, String bookId) {
    final owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
    return owner?.togglePlayback(bookId) ?? false;
  }

  /// 把朗读切到 [chapterId]，并从 [position] 起播（双击跳读，可跨章）。
  ///
  /// 同章就是 seek；换章走 [_openChapter]，它会释放旧播放器、按给定位置起播，
  /// 顺带把进度记下来。找不到这一章（书的章节列表对不上）返回 false。
  static bool jumpToChapter(
    BuildContext context,
    String chapterId,
    Duration position,
  ) {
    final owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
    return owner?.jumpToChapter(chapterId, position) ?? false;
  }

  /// 取指定章节的逐句字幕（阅读页跨章双击跳读用）。
  ///
  /// 正在播的那章直接给会话里已有的轨，不重复请求；其它章按需取一次并缓存。
  /// 取不到（这本书没有生成语音文本）时返回空轨，不算错误。
  static Future<SubtitleTrack> timelineForChapter(
    BuildContext context,
    String chapterId,
  ) {
    final owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
    if (owner == null) return Future.value(SubtitleTrack.empty);
    return owner.timelineForChapter(chapterId);
  }

  @override
  State<AudioPlaybackScope> createState() => _AudioPlaybackScopeState();
}

class _AudioPlaybackScopeState extends State<AudioPlaybackScope> {
  _AudioPlaybackController? _session;
  SystemTtsPlayback? _tts;
  SystemTtsPlayback? _ttsPage;
  Future<void> _queue = Future<void>.value();
  final _views = <_AudioPageState>{};
  bool _rebuildPending = false;
  _AudioPlaybackController? _openingAudio;
  late final Future<void> Function(NativePlayer) _playGate = _beforePlay;

  /// Rebuilds the capsule, which lives in the Navigator's Overlay instead of
  /// under this widget.
  final _tick = ValueNotifier<int>(0);
  AudioFloatingRoutes? _routes;
  RecentListen? _recent;
  bool _resuming = false;
  Object? _toastedError;

  /// 跨章跳读要用的字幕轨缓存，键 = `音色|章节 id`。
  ///
  /// 会话只持有正在播那章的轨，阅读页停在别的章时拿不到字幕；这里按章补取
  /// 一次并缓存。键里带音色，换音色后旧条目自然不再命中。
  final _timelineCache = <String, SubtitleTrack>{};
  final _timelinePending = <String, Future<SubtitleTrack>>{};

  @override
  void initState() {
    super.initState();
    NativePlayer.beforePlay = _playGate;
    unawaited(_loadRecent());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routes = AudioFloatingRouteScope.read(context);
    if (identical(routes, _routes)) return;
    _routes?.unmount();
    _routes = routes;
    routes?.mount(_buildCapsule);
  }

  Future<void> _loadRecent() async {
    final loader = widget.recentListen;
    if (loader == null) return;
    RecentListen? recent;
    try {
      recent = await loader();
    } catch (_) {
      // The idle capsule is a convenience; history read failures hide it.
      return;
    }
    if (!mounted || recent == null || _session != null || _tts != null) return;
    _recent = recent;
    _changed();
  }

  Future<void> _resumeRecent(RecentListen recent, {required bool open}) async {
    if (_resuming) return;
    _resuming = true;
    _changed();
    try {
      final request = await recent.request();
      if (!mounted || !identical(_recent, recent)) return;
      final navigator = widget.navigatorKey.currentState;
      if (open && navigator != null) {
        unawaited(
          navigator.push<void>(MaterialPageRoute(builder: (_) => request)),
        );
      } else {
        await acquire(request);
      }
    } catch (_) {
      _toast('暂时无法继续收听，请稍后重试');
    } finally {
      _resuming = false;
      _changed();
    }
  }

  Future<void> _beforePlay(NativePlayer player) async {
    await _tts?.pause();
    final session = _session;
    if (session == null || session._closed) return;
    if (identical(player, session._player)) {
      await NativePlayer.pauseOthers(player);
    } else {
      await session._pauseForOtherMedia();
    }
  }

  /// 见 [AudioPlaybackScope.seekActive]。会话没就绪（还在缓冲、已关闭）时
  /// 返回 false，不排队 —— 跳读是用户的即时动作，晚半拍就没意义了。
  bool seekActive(Duration position) {
    final session = _session;
    if (session == null || session._closed || !session._ready) return false;
    unawaited(session._seekTo(position));
    return true;
  }

  /// 见 [AudioPlaybackScope.togglePlayback]。
  bool togglePlayback(String bookId) {
    final tts = _tts;
    if (tts != null && !tts.closed && tts.book.bookId == bookId) {
      unawaited(tts.toggle());
      return true;
    }
    final session = _session;
    if (session == null || session._closed) return false;
    // 只控制「正在听的那本」：阅读页可能翻到别的书，那与本会话无关。
    if (session._bookId != bookId || !session._ready) return false;
    unawaited(session._togglePlayback());
    return true;
  }

  /// 见 [AudioPlaybackScope.jumpToChapter]。换章要重新加载音频源，所以不像
  /// [seekActive] 那样要求 _ready —— 正在缓冲中跳读也是合法操作。
  /// 见 [AudioPlaybackScope.timelineForChapter]。
  Future<SubtitleTrack> timelineForChapter(String chapterId) {
    final session = _session;
    if (session == null || session._closed) {
      return Future.value(SubtitleTrack.empty);
    }
    final index = session._chapters.indexWhere((c) => c.itemId == chapterId);
    if (index < 0) return Future.value(SubtitleTrack.empty);
    // 正在播的就是这一章：会话里的轨最新，直接给。
    if (index == session._index && session._subtitles.isNotEmpty) {
      return Future.value(session._subtitles);
    }
    final key = '${session._toneId}|$chapterId';
    final cached = _timelineCache[key];
    if (cached != null) return Future.value(cached);
    final pending = _timelinePending[key];
    if (pending != null) return pending;
    final future = _loadTimeline(
      key,
      session._loadSubtitles(chapterId, session._toneId),
    );
    _timelinePending[key] = future;
    return future;
  }

  Future<SubtitleTrack> _loadTimeline(
    String key,
    Future<SubtitleTrack> load,
  ) async {
    try {
      final track = await load;
      // 命中不了的章不再重复请求；超过 8 条就丢最旧的一条。
      if (_timelineCache.length >= 8) {
        _timelineCache.remove(_timelineCache.keys.first);
      }
      _timelineCache[key] = track;
      return track;
    } finally {
      _timelinePending.remove(key);
    }
  }

  bool jumpToChapter(String chapterId, Duration position) {
    final session = _session;
    if (session == null || session._closed) return false;
    final index = session._chapters.indexWhere((c) => c.itemId == chapterId);
    if (index < 0) return false;
    if (index == session._index) {
      if (!session._ready) return false;
      unawaited(session._seekTo(position));
    } else {
      unawaited(session._openChapter(index, position: position));
    }
    return true;
  }

  Future<_AudioPlaybackController?> acquire(AudioPage request) {
    final next = _queue.then((_) async {
      if (!mounted) return null;
      await _closeTts();
      if (!mounted) return null;
      final current = _session;
      if (current != null &&
          !current._closed &&
          current._bookId == request.bookId) {
        if ((!request.resumeSession || request.startPosition != null) &&
            request.chapters.isNotEmpty) {
          final chapter =
              request.chapters[request.startIndex.clamp(
                0,
                request.chapters.length - 1,
              )];
          final index = current._chapters.indexWhere(
            (c) => c.itemId == chapter.itemId,
          );
          if (index >= 0) {
            unawaited(
              current._openChapter(
                index,
                position: request.startPosition,
                toneId: request.initialToneId,
                restoreHistory: true,
                autoplay: request.autoplay,
              ),
            );
            return current;
          }
          // A refreshed directory can remove an old chapter. Start the exact
          // requested directory instead of silently retaining another chapter.
        } else {
          return current;
        }
      }
      await _closeCurrent();
      if (!mounted) return null;
      final session = _AudioPlaybackController(request);
      _session = session;
      _recent = null;
      session.onStop = () => unawaited(stop(session));
      session.addListener(_changed);
      session.start();
      _changed();
      return session;
    });
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> stop(_AudioPlaybackController session) {
    final next = _queue.then((_) async {
      if (identical(_session, session)) await _closeCurrent();
    });
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _closeCurrent() async {
    final session = _session;
    _session = null;
    session?.removeListener(_changed);
    _changed();
    if (session != null) _retireViews(session);
    await session?.close();
  }

  /// A listening page left in the back stack can't restart a closed session.
  /// Officially closing the capsule exits AudioPlayActivity too, so drop
  /// those pages; the page the user is looking at stays put.
  void _retireViews(_AudioPlaybackController session) {
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    for (final view in _views.toList()) {
      if (!view.mounted || !identical(view._session, session)) continue;
      final route = ModalRoute.of(view.context);
      if (route == null ||
          route.isCurrent ||
          !route.isActive ||
          route.navigator != navigator) {
        continue;
      }
      navigator.removeRoute(route);
    }
  }

  Future<void> startSystemTts(SystemTtsBook book) {
    final next = _queue.then((_) async {
      if (!mounted || book.chapters.isEmpty) return;
      await _closeCurrent();
      await _closeTts();
      if (!mounted) return;
      late final SystemTtsPlayback session;
      session = SystemTtsPlayback(
        book,
        beforePlay: () async {
          if (mounted && identical(_tts, session)) {
            await NativePlayer.pauseOthers();
          }
        },
        onStop: () => unawaited(stopTts(session)),
      );
      _tts = session;
      _recent = null;
      session.addListener(_changed);
      session.start();
      _changed();
    });
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> stopTts(SystemTtsPlayback session) {
    final next = _queue.then((_) async {
      if (identical(_tts, session)) await _closeTts();
    });
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _closeTts() async {
    final session = _tts;
    _tts = null;
    session?.removeListener(_changed);
    _changed();
    await session?.close();
  }

  void _openTts(SystemTtsPlayback session) {
    if (session.closed ||
        !identical(_tts, session) ||
        identical(_ttsPage, session)) {
      return;
    }
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    _ttsPage = session;
    unawaited(
      navigator
          .push<void>(
            MaterialPageRoute<void>(
              builder: (_) => SystemTtsPlaybackPage(
                session: session,
                onClose: () => unawaited(stopTts(session)),
              ),
            ),
          )
          .whenComplete(() {
            if (identical(_ttsPage, session)) _ttsPage = null;
          }),
    );
  }

  void registerView(_AudioPageState view) {
    _views.add(view);
  }

  void unregisterView(_AudioPageState view) {
    _views.remove(view);
  }

  void _openAudio(_AudioPlaybackController session) {
    if (!identical(_session, session) || session._closed) return;
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    for (final view in _views.toList().reversed) {
      if (!view.mounted || !identical(view._session, session)) continue;
      final route = ModalRoute.of(view.context);
      if (route == null || !route.isActive || route.navigator != navigator) {
        continue;
      }
      navigator.popUntil((candidate) => identical(candidate, route));
      return;
    }
    if (identical(_openingAudio, session)) return;
    _openingAudio = session;
    final request = session.request;
    unawaited(
      navigator
          .push<void>(
            MaterialPageRoute<void>(
              builder: (_) => AudioPage(
                bookId: session._bookId,
                title: session._title,
                cover: session._cover,
                chapters: session._chapters,
                startIndex: session._index,
                historyStore: request.historyStore,
                playerFactory: request.playerFactory,
                sourceLoader: request.sourceLoader,
                voicesLoader: request.voicesLoader,
                extrasLoader: request.extrasLoader,
                subtitleLoader: request.subtitleLoader,
                timePointLoader: request.timePointLoader,
                excerptLoader: request.excerptLoader,
                directoryLoader: request.directoryLoader,
                downloadStore: request.downloadStore,
              ),
            ),
          )
          .whenComplete(() {
            if (identical(_openingAudio, session)) _openingAudio = null;
          }),
    );
  }

  void _changed() {
    if (!mounted || _rebuildPending) return;
    _rebuildPending = true;
    // Session acquisition can notify while descendant pages attach.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildPending = false;
      if (!mounted) return;
      _tick.value++;
      _toastNewError();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Officially a playback error is a toast; the capsule falls back to its
  /// play icon (`pn2/i.java` `b.i`). The listening page shows errors inline.
  void _toastNewError() {
    final session = _session;
    final Object? error = session != null && !session._closed
        ? session._error
        : _tts?.error;
    if (error == null) {
      _toastedError = null;
      return;
    }
    if (error == _toastedError || !(_routes?.visible ?? false)) return;
    _toastedError = error;
    _toast(error.toString());
  }

  void _toast(String message) {
    final context = widget.navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    if (identical(NativePlayer.beforePlay, _playGate)) {
      NativePlayer.beforePlay = null;
    }
    final session = _session;
    _session = null;
    session?.removeListener(_changed);
    // Descendant audio/reader views finish detaching before close broadcasts.
    if (session != null) unawaited(Future<void>.microtask(session.close));
    final tts = _tts;
    _tts = null;
    tts?.removeListener(_changed);
    if (tts != null) unawaited(Future<void>.microtask(tts.close));
    _routes?.unmount();
    _routes = null;
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  /// Builds the capsule inside the Navigator's Overlay (see
  /// [AudioFloatingRoutes]). Audio, system TTS and the cold-start idle state
  /// share it: officially TTS is just another session on the same view.
  Widget _buildCapsule(BuildContext context) {
    final routes = _routes;
    if (routes == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([routes, _tick]),
      builder: (context, _) {
        final session = _session;
        final tts = _tts;
        final recent = _recent;
        final visible = routes.visible;
        if (session != null && !session._closed) {
          final error = session._error != null;
          return AudioFloatingPlayer(
            key: ObjectKey(session),
            title: session._title,
            cover: session._cover,
            progress: session._position,
            readProgress: () {
              final duration = session._duration.inMilliseconds;
              return duration <= 0
                  ? 0
                  : session._position.value.inMilliseconds / duration;
            },
            playing:
                (session._player?.playing ?? false) &&
                session._wantPlay &&
                !session._completed,
            loading: session._loading || (session._player?.buffering ?? false),
            // Buffering still pauses; an error retries like the page's button.
            canToggle: error || session._ready,
            visible: visible,
            bottomInset: routes.bottomInset,
            onOpen: () => _openAudio(session),
            onToggle: () => unawaited(
              error
                  ? session._openChapter(session._index, restoreHistory: true)
                  : session._togglePlayback(),
            ),
            onClose: () => unawaited(stop(session)),
          );
        }
        if (tts != null && !tts.closed) {
          return AudioFloatingPlayer(
            key: ObjectKey(tts),
            title: tts.book.title,
            cover: tts.book.coverUrl,
            progress: tts,
            readProgress: () => tts.progress,
            playing: tts.wantPlay,
            loading: tts.loading,
            canToggle: true,
            visible: visible,
            bottomInset: routes.bottomInset,
            onOpen: () => _openTts(tts),
            onToggle: () => unawaited(tts.toggle()),
            onClose: () => unawaited(stopTts(tts)),
          );
        }
        if (recent != null) {
          return AudioFloatingPlayer(
            key: ObjectKey(recent),
            title: recent.title,
            cover: recent.cover,
            progress: _tick,
            readProgress: () => recent.progress,
            playing: false,
            loading: _resuming,
            canToggle: !_resuming,
            // Officially only the home shell attaches the idle ball.
            visible: visible && routes.atRoot,
            bottomInset: routes.bottomInset,
            onOpen: () => unawaited(_resumeRecent(recent, open: true)),
            onToggle: () => unawaited(_resumeRecent(recent, open: false)),
            onClose: () {
              _recent = null;
              _changed();
            },
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}
