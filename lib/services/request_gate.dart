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
/// cancellation retries standalone. Timed joiners retain their own budget
/// across that retry, including when an earlier owner's deadline expires.
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
  /// [timeout] bounds queueing and shared waiting. The sender must pass its
  /// remaining budget to the transport, which owns cancellation of actual IO.
  Future<T> run<T>(
    String key, {
    required Future<T> Function() send,
    BackendRequest? request,
    bool share = true,
    Duration? timeout,
  }) {
    final watch = Stopwatch()..start();
    Duration? remaining() => timeout == null ? null : timeout - watch.elapsed;
    BackendRequestAborted timedOut() =>
        BackendRequestAborted('请求超时', timedOut: true);
    if (request != null && request.isCancelled) {
      return Future<T>.error(BackendRequestAborted('请求已取消'));
    }
    if (timeout != null && timeout <= Duration.zero) {
      return Future<T>.error(timedOut());
    }
    if (share) {
      final existing = _inflight[key];
      if (existing != null) {
        final joined = existing.then<T>(
          (value) => value as T,
          onError: (Object error, StackTrace stack) {
            final retryable =
                (error is BackendRequestAborted &&
                    (!error.timedOut || timeout != null)) ||
                (error is TimeoutException && timeout != null);
            if (retryable && request?.isCancelled != true) {
              // A timed caller has its own budget, not the earlier owner's.
              // Retry only within what remains; cancellation is also local.
              return run<T>(
                key,
                send: send,
                request: request,
                share: false,
                timeout: remaining(),
              );
            }
            Error.throwWithStackTrace(error, stack);
          },
        );
        // Joining does not own the transport flight. Race only this caller's
        // result against its cancellation, leaving the owner's send intact.
        final result = request == null
            ? joined
            : Future.any<T>([
                joined,
                request.whenCancelled.then<T>(
                  (_) => throw BackendRequestAborted('请求已取消'),
                ),
              ]);
        return timeout == null
            ? result
            : result.timeout(timeout, onTimeout: () => throw timedOut());
      }
    }
    final completer = Completer<T>();
    if (share) _inflight[key] = completer.future;
    () async {
      try {
        await _acquire(request, remaining());
      } on Object catch (error, stack) {
        // Cancelled while queued: publish the abort so joiners retry alone.
        completer.completeError(error, stack);
        if (share) _inflight.remove(key);
        return;
      }
      try {
        if (remaining() case final left? when left <= Duration.zero) {
          throw timedOut();
        }
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

  Future<void> _acquire(BackendRequest? request, Duration? timeout) async {
    if (timeout != null && timeout <= Duration.zero) {
      throw BackendRequestAborted('请求超时', timedOut: true);
    }
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    while (true) {
      final waiter = _Waiter();
      _waiters.addLast(waiter);
      var cancelled = false;
      var timedOut = false;
      final ready = request == null
          ? waiter.grant.future
          : Future.any([
              waiter.grant.future,
              request.whenCancelled.then((_) => cancelled = true),
            ]);
      if (timeout == null) {
        await ready;
      } else {
        await ready.timeout(
          timeout,
          onTimeout: () {
            timedOut = true;
          },
        );
      }
      if (cancelled || request?.isCancelled == true || timedOut) {
        // A grant and cancellation can complete in the same event-loop turn.
        // If the slot moved to us, hand it on exactly once; run() must not
        // start send() or release that same slot again.
        if (waiter.granted) {
          _release();
        } else {
          _waiters.remove(waiter);
        }
        final wasCancelled = cancelled || request?.isCancelled == true;
        throw BackendRequestAborted(
          wasCancelled ? '请求已取消' : '请求超时',
          timedOut: !wasCancelled,
        );
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
