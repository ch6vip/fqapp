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

  Future<SubtitleTrack> _loadTimeline(String key, Future<SubtitleTrack> load) async {
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

  void _open(_AudioPlaybackController session) {
    if (session._closed || !identical(_session, session)) return;
    final request = session.request;
    unawaited(
      widget.navigatorKey.currentState?.push<void>(
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
            excerptLoader: request.excerptLoader,
            directoryLoader: request.directoryLoader,
          ),
        ),
      ),
    );
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

  // The mini bars below are siblings of the Navigator, not descendants,
  // so they have no Overlay ancestor for their IconButton tooltips
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
    final session = _session;
    final tts = _tts;
    final showBar =
        session != null &&
        !session._closed &&
        !_views.any((v) => v._routeCurrent && identical(v._session, session));
    return Column(
      children: [
        Expanded(child: widget.child),
        if (tts != null && !tts.closed)
          SystemTtsMiniBar(
            session: tts,
            onOpen: () => _openTts(tts),
            onClose: () => unawaited(stopTts(tts)),
          ),
        if (showBar)
          Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        key: const ValueKey('audio-mini-open'),
                        onTap: () => _open(session),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                session._title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              Text(
                                session._error != null
                                    ? '播放失败，查看详情'
                                    : session._loading
                                    ? '正在加载…'
                                    : session._chapters.isEmpty
                                    ? '暂无章节'
                                    : session._chapters[session._index].title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const _FollowToggle(),
                    IconButton(
                      key: const ValueKey('audio-mini-toggle'),
                      tooltip: session._wantPlay && !session._completed
                          ? '暂停听书'
                          : '继续听书',
                      onPressed: session._ready
                          ? session._togglePlayback
                          : null,
                      icon: Icon(
                        session._wantPlay && !session._completed
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('audio-mini-close'),
                      tooltip: '关闭听书',
                      onPressed: () => unawaited(stop(session)),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 迷你栏的「跟随」开关：按一次开跟随并跳到播放位置，再按一次放开自由翻页。
///
/// 状态存在 [ListeningSession.followArmed] 上，图标由本组件自己管 —— 迷你栏
/// 整条由 OverlayEntry 重建，单独抽出来才不会被拖着整条一起刷。
class _FollowToggle extends StatefulWidget {
  const _FollowToggle();

  @override
  State<_FollowToggle> createState() => _FollowToggleState();
}

class _FollowToggleState extends State<_FollowToggle> {
  @override
  void initState() {
    super.initState();
    // 阅读页手动翻页会退出跟随，图标得跟着变回来；迷你栏挂在 Overlay 上，
    // 只能听会话的通知。
    ListeningSession.instance.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    ListeningSession.instance.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final armed = ListeningSession.instance.followArmed;
    // 处理函数由阅读页注册/注销，按钮的可点状态得跟着它走。迷你栏挂在
    // Overlay 上、不会为这个重建，所以直接在构建里读那个 notifier：
    // 只在真的换了函数时通知一次（同值不通知），不会变成每帧重刷。
    return ValueListenableBuilder<void Function()?>(
      valueListenable: ListeningSession.instance.jumpToPlaybackHandlerListenable,
      builder: (context, handler, _) => IconButton(
        key: const ValueKey('audio-mini-jump'),
        // 点一次就跳到朗读处（不管之前开没开），长按才是停止跟随 ——
        // 之前是「点一下切开关」，已经在跟随时再点只会关掉、不会重新定位，
        // 想回到朗读处就得点两次。
        tooltip: armed ? '跟随中，点按回到朗读处；长按停止跟随' : '点按跳到朗读处并跟随',
        onPressed: handler == null
            ? null
            : () {
                ListeningSession.instance.setFollowArmed(true);
                handler();
              },
        onLongPress: armed
            ? () => ListeningSession.instance.setFollowArmed(false)
            : null,
        icon: Icon(
          armed ? Icons.gps_fixed : Icons.my_location,
          // 跟随中染主色：一眼能看出「页面正在被朗读带着走」。
          color: armed ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
    );
  }
}
