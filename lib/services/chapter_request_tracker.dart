import 'backend_transport.dart';

/// Cancellation handles for chapter fetches, one per chapter id.
///
/// Prefetching the neighbouring chapters and refreshing a cached chapter run
/// alongside the foreground fetch. A single shared handle let each of them
/// cancel the others, so one prefetched neighbour was always dropped and a
/// refresh could abort the chapter the reader was opening. Keying by chapter
/// id scopes cancellation to a newer request for the same chapter;
/// [cancelAll] covers leaving the page.
class ChapterRequestTracker {
  final Map<String, BackendRequest> _requests = {};

  /// Starts a fetch for [chapterId], superseding that chapter's previous
  /// request if it is still in flight.
  BackendRequest start(String chapterId) {
    _requests.remove(chapterId)?.cancel();
    final request = BackendRequest();
    _requests[chapterId] = request;
    return request;
  }

  /// Releases [request] once it settles. A newer request that already took its
  /// place keeps its handle.
  void finish(String chapterId, BackendRequest request) {
    if (identical(_requests[chapterId], request)) _requests.remove(chapterId);
  }

  /// Cancels every in-flight fetch; the page is going away.
  void cancelAll() {
    for (final request in _requests.values.toList()) {
      request.cancel();
    }
    _requests.clear();
  }
}
