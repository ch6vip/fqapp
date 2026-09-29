import 'dart:async';
import 'dart:collection';

import 'backend_transport.dart';

/// Global throttle for backend reads.
///
/// Two protections share one gate, both borrowed from the short-drama
/// aggregator's request discipline:
///
/// - **Coalescing** — a `GET` while the identical request (method, URL and
///   timeout) is already in flight joins that flight instead of stacking a
///   second upstream call. Rapid tab switches and double taps produce exactly
///   these duplicates. POSTs and bodies never share.
/// - **Cap** — at most [maxConcurrent] requests talk to the Rust core at once;
///   the rest queue FIFO. A queued caller whose [BackendRequest] is cancelled
///   leaves the queue immediately instead of starting work it will discard.
///
/// Cancellation stays with the transport: the gate never aborts a send itself,
/// it only refuses to start one. A joiner whose flight dies with its owner's
/// cancellation retries standalone, so its own data does not die with somebody
/// else's request.
class RequestGate {
  // Note: Shared-flight cancellation and queued slot ownership — see
  // .agents/notes/implemented/bug-fix/2026-09-28-request-gate-cancellation.md.
  RequestGate({this.maxConcurrent = 16});

  final int maxConcurrent;

  int _active = 0;
  final Queue<_Waiter> _waiters = Queue();
  final Map<String, Future<Object?>> _inflight = {};

  /// Runs [send] under the gate. [key] must uniquely describe the request for
  /// sharing purposes; pass `share: false` to skip coalescing.
  Future<T> run<T>(
    String key, {
    required Future<T> Function() send,
    BackendRequest? request,
    bool share = true,
  }) {
    if (request != null && request.isCancelled) {
      return Future<T>.error(BackendRequestAborted('请求已取消'));
    }
    if (share) {
      final existing = _inflight[key];
      if (existing != null) {
        final joined = existing.then<T>(
          (value) => value as T,
          onError: (Object error, StackTrace stack) {
            if (error is BackendRequestAborted &&
                request?.isCancelled != true) {
              // The flight we joined was aborted by its owner's cancellation.
              // Retry standalone so this caller still gets its answer.
              return run<T>(key, send: send, request: request, share: false);
            }
            Error.throwWithStackTrace(error, stack);
          },
        );
        if (request == null) return joined;
        // Joining does not own the transport flight. Race only this caller's
        // result against its cancellation, leaving the owner's send intact.
        return Future.any<T>([
          joined,
          request.whenCancelled.then<T>(
            (_) => throw BackendRequestAborted('请求已取消'),
          ),
        ]);
      }
    }
    final completer = Completer<T>();
    if (share) _inflight[key] = completer.future;
    () async {
      try {
        await _acquire(request);
      } on Object catch (error, stack) {
        // Cancelled while queued: publish the abort so joiners retry alone.
        completer.completeError(error, stack);
        if (share) _inflight.remove(key);
        return;
      }
      try {
        completer.complete(await send());
      } on Object catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        _release();
        if (share) _inflight.remove(key);
      }
    }();
    return completer.future;
  }

  Future<void> _acquire(BackendRequest? request) async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    while (true) {
      final waiter = _Waiter();
      _waiters.addLast(waiter);
      var cancelled = false;
      if (request != null) {
        await Future.any([
          waiter.grant.future,
          request.whenCancelled.then((_) => cancelled = true),
        ]);
      } else {
        await waiter.grant.future;
      }
      if (cancelled || request?.isCancelled == true) {
        // A grant and cancellation can complete in the same event-loop turn.
        // If the slot moved to us, hand it on exactly once; run() must not
        // start send() or release that same slot again.
        if (waiter.granted) {
          _release();
        } else {
          _waiters.remove(waiter);
        }
        throw BackendRequestAborted('请求已取消');
      }
      return;
    }
  }

  void _release() {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      waiter.granted = true;
      waiter.grant.complete();
      // The slot moves to the waiter, so the active count stays.
      return;
    }
    _active--;
  }
}

class _Waiter {
  final Completer<void> grant = Completer<void>();
  bool granted = false;
}
