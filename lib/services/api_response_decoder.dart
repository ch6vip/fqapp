import 'dart:async';
import 'dart:isolate';

/// Envelope bodies at or below this size decode on the calling isolate:
/// spawning a background isolate costs more than the JSON decode itself.
const int inlineDecodeLimit = 64 * 1024;

/// Runs a decode that is large enough to be worth leaving the calling isolate.
///
/// A seam rather than a direct [Isolate.run] call, so tests can prove small
/// bodies never take the hop.
Future<T> Function<T>(FutureOr<T> Function() computation) decodeIsolateRunner =
    Isolate.run;

/// Decodes one response body, keeping small envelopes on the calling isolate
/// and moving large ones off the UI thread.
///
/// [bodyLength] is the raw byte count; [decode] does the JSON work and returns
/// the value to hand back to the caller.
Future<T> decodeResponseBody<T>(int bodyLength, T Function() decode) async {
  if (bodyLength <= inlineDecodeLimit) return decode();
  return decodeIsolateRunner(decode);
}
