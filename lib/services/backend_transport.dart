import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../src/rust/api.dart' as rust;
import '../src/rust/frb_generated.dart';

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
  BackendRequestAborted(this.message);

  final String message;

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

/// [baseUrl] with [capability] woven into the path, ending in `/`.
///
/// Resource URLs must use this: backend-relative paths are root-relative
/// (`/src/...`) and `Uri.resolve` would otherwise replace the whole base path,
/// dropping the capability. `resolveBackendResource` re-anchors them.
///
/// A free function rather than an interface member, so that every
/// `implements BackendTransport` (test doubles included) stays untouched.
String backendResourceBase(String baseUrl, String capability) =>
    capability.isEmpty ? '$baseUrl/' : '$baseUrl/_session/$capability/';

/// A backend call surface. Two implementations share the same Rust core:
/// [RustBackendTransport] calls it over flutter_rust_bridge, and
/// [HttpBackendTransport] talks to the loopback HTTP adapter (tests, desktop,
/// Web).
abstract class BackendTransport {
  /// Base URL used to resolve backend-relative resources such as `/src/...`.
  String get baseUrl;

  /// Per-launch capability the loopback adapter requires; empty when unknown.
  ///
  /// Only callers that cross the socket must present it - FFI calls stay in
  /// process and are never gated.
  String get capability => '';

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
  RustBackendTransport({this.port = 8080, this.mockUpstreamOrigin = ''})
    : _baseUrl = 'http://127.0.0.1:$port',
      // Created eagerly so it captures the ambient `http.Client` of the Zone
      // that built this transport. That is what keeps `ApiClient` injectable:
      // a Dart test that replaces `http.Client` through `http.runWithClient`
      // still drives the same request surface before the core is up.
      _httpFallback = HttpBackendTransport(
        baseUrl: 'http://127.0.0.1:$port',
      );

  final int port;

  /// Empty in the shipping app. The host integration test sets it to a local
  /// mock server so the real FFI path can be verified offline.
  final String mockUpstreamOrigin;

  /// Process-wide flutter_rust_bridge runtime handle.
  ///
  /// The bridge refuses a second `RustLib.init()`, and the flag has to be
  /// static: a second transport instance in the same process (a restarted
  /// service, a test) must reuse the runtime instead of initializing it again.
  static Future<void>? _runtimeReady;

  String _baseUrl;
  String _capability = '';
  bool _coreRunning = false;

  /// Loads the bridge runtime once per process.
  static Future<void> ensureRuntime() => _runtimeReady ??= RustLib.init();

  /// Records that the runtime is already initialized, for hosts that load the
  /// shared library themselves (the host integration test opens an explicit
  /// path).
  static void markRuntimeReady() {
    _runtimeReady ??= Future<void>.value();
  }
  final HttpBackendTransport _httpFallback;

  @override
  String get baseUrl => _baseUrl;

  @override
  String get capability => _capability;

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
    final result = await rust.init(
      configPath: configPath,
      poolPath: poolPath,
      filterPath: filterPath,
      runtimeDir: runtimeDir,
      port: port,
      mockUpstreamOrigin: mockUpstreamOrigin,
    );
    _baseUrl = await rust.baseUrl();
    _capability = await rust.sessionCapability();
    _httpFallback.capability = _capability;
    _coreRunning = result == 'running';
    return result;
  }

  Future<String> status() async {
    if (!_coreRunning) return 'starting';
    return rust.status();
  }

  Future<void> stop() async {
    if (!_coreRunning) return;
    // The Rust core cancels every in-flight call before dropping the server, so
    // a pending page load cannot publish a result after shutdown.
    _coreRunning = false;
    await rust.shutdown();
  }

  @override
  Future<void> close() async {
    await _httpFallback.close();
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
      return _httpFallback.send(
        method,
        url,
        body: body,
        timeout: timeout,
        request: request,
      );
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
        throw BackendRequestAborted('请求超时');
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

/// HTTP transport for the loopback adapter, Dart tests and the Web build.
class HttpBackendTransport implements BackendTransport {
  HttpBackendTransport({
    http.Client? client,
    required this.baseUrl,
    this.capability = '',
  }) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  final String baseUrl;

  /// Loopback capability presented as a bearer token; empty when the caller
  /// talks to a server that does not ask for one.
  ///
  /// Mutable because the FFI transport only learns it once the core is up.
  @override
  String capability;

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

    final httpRequest = http.AbortableRequest(
      method,
      url,
      abortTrigger: abort.future,
    );
    if (body != null) httpRequest.bodyBytes = body;
    if (capability.isNotEmpty) {
      // This is the only HTTP path that never sees the cookie the entry URL
      // sets, so it has to present the capability as a bearer token.
      httpRequest.headers['authorization'] = 'Bearer $capability';
    }
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
