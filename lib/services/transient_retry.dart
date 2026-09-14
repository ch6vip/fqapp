import 'dart:async';

/// Retries a transient async failure a few times with linear backoff.
///
/// The in-app backend draws a pooled device per upstream request. The audio
/// player host occasionally rejects that device with a body-level 403 inside
/// an HTTP 200 ("invalid aid"); the next draw usually succeeds, so the
/// listening page retries the source fetch before surfacing an error.
Future<T> retryTransient<T>(
  Future<T> Function() task, {
  int attempts = 3,
  Duration baseDelay = const Duration(milliseconds: 200),
}) async {
  if (attempts < 1) {
    throw ArgumentError.value(attempts, 'attempts', 'must be at least 1');
  }
  Object? lastError;
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      return await task();
    } catch (error) {
      lastError = error;
      if (attempt + 1 < attempts) {
        await Future<void>.delayed(baseDelay * (attempt + 1));
      }
    }
  }
  throw lastError!;
}
