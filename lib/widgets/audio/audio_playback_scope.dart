part of '../../pages/audio_page.dart';

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

  /// 在后台起播，不打开听书页（阅读页「从本页听」用它）。
  ///
  /// 会话由 scope 持有、页面只是视图，所以不挂载页面也能播；阅读页留在
  /// 原处继续跟随与高亮。返回 false 表示入口不支持或起播失败。
  static Future<bool> startListeningInBackground(
    BuildContext context,
    AudioPage request,
  ) async {
    final owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
    if (owner == null) return false;
    return await owner.acquire(request) != null;
  }

  /// 段落锚点跳转（双击跳读用）：与「从本页播放」同一套寻址。
  static bool jumpToParagraph(BuildContext context, String chapterId,
      {required int? paraIndex, required int ordinal}) {
    final owner = context.findAncestorStateOfType<_AudioPlaybackScopeState>();
    return owner?.jumpToParagraph(chapterId, paraIndex: paraIndex, ordinal: ordinal) ?? false;
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

  /// 阅读页手动翻页：把这本书的播放暂停。
  ///
  /// 官方 `handlePlayWhenPageChange`（`AudioSyncReaderController.java:1242-1295`）
  /// 在同章翻页时 `pausePlayer()` 并亮出「原进度 / 从本页听」。和
  /// [togglePlayback] 不同，这里只在正在播时暂停；已经是暂停态时调用不会反着
  /// 播起来。
  static void pauseIfPlaying(BuildContext context, String bookId) {
    context
        .findAncestorStateOfType<_AudioPlaybackScopeState>()
        ?.pauseIfPlaying(bookId);
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

  /// 见 [AudioPlaybackScope.pauseIfPlaying]。
  void pauseIfPlaying(String bookId) {
    final tts = _tts;
    if (tts != null && !tts.closed && tts.book.bookId == bookId) {
      if (tts.wantPlay || tts.loading) unawaited(tts.pause());
      return;
    }
    final session = _session;
    if (session == null || session._closed) return;
    if (session._bookId != bookId || !session._ready) return;
    if (session._wantPlay) unawaited(session._pauseForOtherMedia());
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

  /// 见 [AudioPlaybackScope.jumpToParagraph]。段落锚点交给播放器的
  /// `/timepoints` 解析，不依赖字幕轨 —— 跨页/跨章时手里的字幕轨对不上
  /// 本章正文，这条才是可靠的寻址路径。
  bool jumpToParagraph(
    String chapterId, {
    required int? paraIndex,
    required int ordinal,
  }) {
    final session = _session;
    if (session == null || session._closed) return false;
    final index = session._chapters.indexWhere((c) => c.itemId == chapterId);
    if (index < 0) return false;
    unawaited(session._openChapter(index, paragraph: (paraIndex: paraIndex, ordinal: ordinal)));
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
                paragraph: request.startParagraph,
                fraction: request.startFraction,
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
}
