part of '../../pages/audio_page.dart';

/// Owns one listening session for the lifetime of the app's Navigator.
class AudioPlaybackScope extends StatefulWidget {
  const AudioPlaybackScope({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

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
  late final Future<void> Function(NativePlayer) _playGate = _beforePlay;

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

  void viewChanged(_AudioPageState view) {
    _views.add(view);
    _changed();
  }

  void removeView(_AudioPageState view) {
    _views.remove(view);
    _changed();
  }

  void _changed() {
    if (!mounted || _rebuildPending) return;
    _rebuildPending = true;
    // Views attach/detach while Navigator builds. Defer the ancestor rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildPending = false;
      if (mounted) setState(() {});
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
    super.dispose();
  }

  // The bar below is a sibling of the Navigator, not a descendant,
  // so it has no Overlay ancestor for its IconButton tooltips
  // (the Navigator owns its own Overlay internally). Wrap the column
  // in an Overlay so the tooltips resolve to this outer Overlay, while
  // route content still resolves to the Navigator's inner Overlay.
  //
  // The entry is created once: Overlay only reads initialEntries in
  // initState, so an entry rebuilt in build() would never be inserted
  // and its builder would stay frozen on the first build's values
  // (mini bars never appearing). The builder below reads live state,
  // so each scope rebuild re-renders the bars with current values.
  late final OverlayEntry _entry = OverlayEntry(builder: _buildEntry);

  @override
  Widget build(BuildContext context) {
    return Overlay(initialEntries: [_entry]);
  }

  Widget _buildEntry(BuildContext context) {
    final tts = _tts;
    return Column(
      children: [
        Expanded(child: widget.child),
        // 官方 7.0.9.32 没有任何迷你播放器产物（id/layout/smali 全量搜过都是 0），
        // 离开听书页后只由通知栏控制，所以这里不再挂听书迷你栏。
        if (tts != null && !tts.closed)
          SystemTtsMiniBar(
            session: tts,
            onOpen: () => _openTts(tts),
            onClose: () => unawaited(stopTts(tts)),
          ),
      ],
    );
  }
}
