import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_client.dart';

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
  bool Function(Object error)? shouldRetry,
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
      // Deterministic failures (a business code that will answer the same way
      // every time) must not burn the remaining attempts and their backoff;
      // callers that can tell them apart pass [shouldRetry].
      if (shouldRetry != null && !shouldRetry(error)) break;
      if (attempt + 1 < attempts) {
        await Future<void>.delayed(baseDelay * (attempt + 1));
      }
    }
  }
  throw lastError!;
}

/// Whether [error] is a transient failure worth another attempt.
///
/// The local backend draws a pooled device per upstream request: a dropped
/// connection, HTTP 408/429 or a 5xx can succeed on the next draw. Everything
/// else is deterministic - a timeout already spent its deadline, another 4xx
/// (404/403) and upstream business codes (NO_THIS_TONE, audit rejection) answer
/// the same way every time - so retrying only delays the same failure. Callers
/// that put a per-attempt deadline on a request (the audio source fetch allows
/// 30 seconds) must not turn one failure into minutes of waiting.
bool isTransientNetworkFailure(Object error) {
  if (error is ApiException) {
    final status = error.statusCode;
    if (status == null) return false;
    return status == HttpStatus.requestTimeout ||
        status == HttpStatus.tooManyRequests ||
        status >= 500;
  }
  return error is SocketException ||
      error is HttpException ||
      error is http.ClientException;
}
