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

/// The capsule half of [_AudioPlaybackScopeState]: it lives in the
/// Navigator's Overlay, while the state owns sessions and their queue.
extension _AudioCapsule on _AudioPlaybackScopeState {
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
