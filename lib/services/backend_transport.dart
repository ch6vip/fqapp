import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../src/rust/api.dart' as rust;
import '../src/rust/frb_generated.dart';
import 'secure_key_provider.dart';

/// One backend response.
///
/// The transport keeps the HTTP shape (status + bytes) because the whole
/// business contract - including "HTTP 200 with a business error code" - is
/// expressed that way by the Rust core.
class BackendResponse {
  const BackendResponse(this.statusCode, this.body, this.contentType);

  final int statusCode;
  final Uint8List body;
  final String contentType;
}

/// Raised when a call was cancelled, or exceeded its deadline.
///
/// Cancelling drops the in-flight Rust dispatch future, which tears down the
/// awaiting upstream request, any retry backoff and any not-yet-submitted
/// write - so a late result is never published. A filesystem write the OS has
/// already accepted is not rolled back: Tokio file I/O is not a transaction.
class BackendRequestAborted implements Exception {
  BackendRequestAborted(this.message, {this.timedOut = false});

  final String message;

  /// The core hit its deadline instead of the caller cancelling. The two are
  /// different events: a joiner must not treat a timeout as "the owner
  /// cancelled" and re-send a request that already ran out of time.
  final bool timedOut;

  @override
  String toString() => message;
}

/// Cancellation handle for one logical unit of work.
///
/// A page (or a feed loader) creates one, asks [ApiClient.withCancellation] to
/// bind its requests to it, and cancels it when the page goes away or a newer
/// request supersedes it. Cancelling is idempotent and always safe.
class BackendRequest {
  final List<void Function()> _cancellers = [];
  bool _cancelled = false;
  final Completer<void> _cancelledSignal = Completer<void>();

  bool get isCancelled => _cancelled;

  /// Completes when [cancel] is called. A request that is already cancelled
  /// resolves immediately.
  Future<void> get whenCancelled => _cancelledSignal.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledSignal.complete();
    for (final cancel in List<void Function()>.of(_cancellers)) {
      cancel();
    }
    _cancellers.clear();
  }

  /// Registers [cancel]. Returns false - after cancelling immediately - when
  /// this request was already cancelled, which is how a caller that lost a race
  /// learns it must not start the work at all.
  bool register(void Function() cancel) {
    if (_cancelled) {
      cancel();
      return false;
    }
    _cancellers.add(cancel);
    return true;
  }

  void unregister(void Function() cancel) {
    _cancellers.remove(cancel);
  }
}

/// A backend call surface. [RustBackendTransport] calls the core over
/// flutter_rust_bridge; [HttpBackendTransport] is a plain HTTP transport
/// tests use against a mock server. There is no socket in production: the
/// core runs in-process and nothing listens on a port.
abstract class BackendTransport {
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  });

  Future<void> close() async {}
}

/// flutter_rust_bridge transport. The Rust core owns the HTTP client, the
/// device pool and the signing keys; Dart only passes method/path/query/body.
class RustBackendTransport implements BackendTransport {
  RustBackendTransport({this.mockUpstreamOrigin = ''});

  /// Empty in the shipping app. The host integration test sets it to a local
  /// mock server so the real FFI path can be verified offline.
  final String mockUpstreamOrigin;

  /// Process-wide flutter_rust_bridge runtime handle.
  ///
  /// The bridge refuses a second `RustLib.init()`, and the flag has to be
  /// static: a second transport instance in the same process (a restarted
  /// service, a test) must reuse the runtime instead of initializing it again.
  static Future<void>? _runtimeReady;

  bool _coreRunning = false;

  /// Loads the bridge runtime once per process.
  static Future<void> ensureRuntime() => _runtimeReady ??= RustLib.init();

  /// Records that the runtime is already initialized, for hosts that load the
  /// shared library themselves (the host integration test opens an explicit
  /// path).
  static void markRuntimeReady() {
    _runtimeReady ??= Future<void>.value();
  }

  /// Process-wide monotonic id source.
  ///
  /// Request ids are registered in one global table inside the Rust core, so
  /// they must be unique across transport instances too - an instance-local
  /// counter would let two transports (a restarted service, a test) collide and
  /// cancel each other's calls.
  static int _requestIdCounter = 0;

  /// Allocates the next request id. Exposed so the uniqueness invariant can be
  /// tested without loading the shared library.
  static String nextRequestId() => 'fq-${_requestIdCounter++}';

  /// Initializes the Rust runtime and the backend core. Idempotent: concurrent
  /// and repeated calls converge on the same core.
  Future<String> start({
    required String configPath,
    required String poolPath,
    required String filterPath,
    required String runtimeDir,
  }) async {
    await ensureRuntime();
    // P1-2: provision the device-pool encryption key before init, so the
    // Rust core reads an encrypted pool file on its first load. A null
    // key (secure storage unavailable) keeps the old plaintext behavior;
    // a provisioning failure never blocks startup.
    final poolKey = await SecureKeyProvider().devicePoolKey();
    if (poolKey != null) {
      try {
        await rust.setDevicePoolKey(key: poolKey);
      } catch (_) {
        // Keep starting: the pool falls back to plaintext + a warning.
      }
    }
    final result = await rust.init(
      configPath: configPath,
      poolPath: poolPath,
      filterPath: filterPath,
      runtimeDir: runtimeDir,
      mockUpstreamOrigin: mockUpstreamOrigin,
    );
    _coreRunning = result == 'running';
    return result;
  }

  Future<String> status() async {
    if (!_coreRunning) return 'starting';
    return rust.status();
  }

  Future<void> stop() async {
    if (!_coreRunning) return;
    // The Rust core cancels every in-flight call before dropping the core, so
    // a pending page load cannot publish a result after shutdown.
    _coreRunning = false;
    await rust.shutdown();
  }

  @override
  Future<void> close() async {
    await stop();
  }

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    if (request != null && request.isCancelled) {
      throw BackendRequestAborted('请求已取消');
    }
    if (!_coreRunning) {
      throw StateError('backend not running');
    }

    final requestId = nextRequestId();
    void cancelInRust() {
      unawaited(rust.cancel(requestId: requestId));
    }

    if (request != null && !request.register(cancelInRust)) {
      throw BackendRequestAborted('请求已取消');
    }

    final pending = rust.request(
      requestId: requestId,
      method: method,
      path: url.path,
      query: url.query,
      body: body ?? Uint8List(0),
      timeoutMs: timeout?.inMilliseconds ?? 0,
    );

    try {
      final response = request == null
          ? await pending
          : await Future.any<rust.BridgeResponse?>([
              pending,
              request.whenCancelled.then((_) => null),
            ]);
      if (response == null) {
        cancelInRust();
        throw BackendRequestAborted('请求已取消');
      }
      if (response.status == 499) {
        throw BackendRequestAborted('请求已取消');
      }
      if (response.status == 504) {
        throw BackendRequestAborted('请求超时', timedOut: true);
      }
      return BackendResponse(
        response.status,
        response.body,
        response.contentType,
      );
    } finally {
      request?.unregister(cancelInRust);
    }
  }
}

/// Plain HTTP transport for tests (a mock server). Path-only request URIs
/// resolve against [baseUrl]; absolute URIs pass through untouched.
class HttpBackendTransport implements BackendTransport {
  HttpBackendTransport({http.Client? client, required this.baseUrl})
    : _client = client ?? http.Client();

  final http.Client _client;

  final String baseUrl;

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    if (request != null && request.isCancelled) {
      throw BackendRequestAborted('请求已取消');
    }
    final abort = Completer<void>();
    void abortNow() {
      if (!abort.isCompleted) abort.complete();
    }

    if (request != null && !request.register(abortNow)) {
      throw BackendRequestAborted('请求已取消');
    }

    final resolved = url.hasScheme ? url : Uri.parse(baseUrl).resolveUri(url);
    final httpRequest = http.AbortableRequest(
      method,
      resolved,
      abortTrigger: abort.future,
    );
    if (body != null) httpRequest.bodyBytes = body;
    try {
      // The deadline must cover reading the body too: a server that sends
      // headers and then stalls would otherwise hold the connection forever.
      final response = await _client
          .send(httpRequest)
          .then(http.Response.fromStream)
          .timeout(timeout ?? const Duration(seconds: 20));
      return BackendResponse(
        response.statusCode,
        response.bodyBytes,
        response.headers['content-type'] ?? '',
      );
    } catch (error) {
      // A timed-out or cancelled exchange must not keep occupying a connection.
      abortNow();
      if (request != null &&
          request.isCancelled &&
          error is! BackendRequestAborted) {
        throw BackendRequestAborted('请求已取消');
      }
      rethrow;
    } finally {
      request?.unregister(abortNow);
    }
  }

  @override
  Future<void> close() async {
    _client.close();
  }
}
