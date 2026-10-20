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
