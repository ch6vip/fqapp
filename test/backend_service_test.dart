import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/backend_service.dart';
import 'package:fqapp/services/backend_transport.dart';

/// Lifecycle tests for the Rust-backed [BackendService].
///
/// The Go/JNI/process assumptions of the previous suite are replaced by the
/// equivalent Rust guarantees: in-process initialization, idempotent start,
/// a health gate on the loopback adapter, generation-isolated stop/restart, and
/// runtime asset deployment that never clobbers the registered device pool.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  BackendService? created;

  BackendService createBackend({
    AssetBundle? assets,
    Duration timeout = const Duration(seconds: 2),
    Duration shutdownTimeout = const Duration(seconds: 3),
    BackendTransport? transport,
  }) {
    final backend = BackendService(
      assets: assets ?? _BackendAssets(),
      supportDirectory: () async => directory,
      transport: transport ?? _FakeRustTransport(),
      startupTimeout: timeout,
      shutdownTimeout: shutdownTimeout,
    );
    created = backend;
    return backend;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fqapp_backend_test_');
  });

  tearDown(() async {
    await created?.stop();
    // The log writer may still hold the file on Windows; a leaked temp
    // directory must not turn a passing test red.
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // ignored
    }
  });

  test('concurrent starts run one initialization and share the result', () async {
    final transport = _FakeRustTransport();
    final backend = createBackend(transport: transport);

    final first = backend.start();
    final second = backend.start();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);

    expect(transport.initCalls, 1);
    expect(backend.isRunning, isTrue);
    await backend.stop();
    expect(transport.stopCalls, 1);
    expect(backend.isRunning, isFalse);
  });

  test('a failed core initialization surfaces and leaves nothing running', () async {
    final transport = _FakeRustTransport(initResult: 'failed: listen busy');
    final backend = createBackend(transport: transport);

    await expectLater(backend.start(), throwsStateError);
    expect(backend.isRunning, isFalse);
    // A failed start performs its own cleanup so a retry is not blocked.
    transport.initResult = 'running';
    await backend.start();
    expect(backend.isRunning, isTrue);
    expect(transport.initCalls, 2);
    await backend.stop();
  });

  test('startup times out when the health endpoint never turns 200', () async {
    final transport = _FakeRustTransport(healthy: false);
    final backend = createBackend(
      transport: transport,
      timeout: const Duration(milliseconds: 200),
    );

    await expectLater(
      backend.start().timeout(const Duration(seconds: 3)),
      throwsStateError,
    );
    expect(backend.isRunning, isFalse);
    expect(transport.healthChecks, greaterThan(0));
  });

  test('stop during deployment waits and shuts the core down', () async {
    final assets = _BackendAssets(blockFirstLoad: true);
    final transport = _FakeRustTransport();
    final backend = createBackend(assets: assets, transport: transport);

    final starting = backend.start();
    await assets.loadEntered.future;
    final stopping = backend.stop();
    assets.allowLoad.complete();
    await starting;
    await stopping;

    expect(transport.initCalls, 1);
    expect(transport.stopCalls, 1);
    expect(backend.isRunning, isFalse);
  });

  test('a start during shutdown waits and initializes a new core', () async {
    final transport = _FakeRustTransport(blockStop: true);
    final backend = createBackend(transport: transport);
    await backend.start();

    final stopping = backend.stop();
    await transport.stopEntered.future;
    final restarting = backend.start();
    transport.allowStop.complete();
    await stopping;
    await restarting;

    expect(transport.initCalls, 2);
    expect(transport.stopCalls, 1);
    expect(backend.isRunning, isTrue);
    await backend.stop();
  });

  test('stop is safe to call repeatedly and without a start', () async {
    final transport = _FakeRustTransport();
    final backend = createBackend(transport: transport);
    await backend.stop();
    await backend.stop();
    expect(transport.stopCalls, 0);
    expect(backend.isRunning, isFalse);
  });

  test('deploys nested runtime assets and keeps the registered device pool',
      () async {
    final transport = _FakeRustTransport();
    final backend = createBackend(transport: transport);
    await backend.start();

    for (final path in _BackendAssets.runtimeAssets) {
      final file = File(
        '${directory.path}/backend/${path.substring('assets/'.length)}',
      );
      expect(await file.readAsString(), '{}', reason: path);
    }

    // The pool holds real device credentials: a restart must not overwrite it.
    final pool = File('${directory.path}/backend/config/device_pool.json');
    await pool.writeAsString('registered-device');
    final stylesheet = File(
      '${directory.path}/backend/web/assets/css/all.min.css',
    );
    await stylesheet.writeAsString('old stylesheet');
    await backend.stop();

    await backend.start();
    expect(await pool.readAsString(), 'registered-device');
    expect(await stylesheet.readAsString(), '{}');
    await backend.stop();
  });

  test('the core is initialized with the deployed runtime paths', () async {
    final transport = _FakeRustTransport();
    final backend = createBackend(transport: transport);
    await backend.start();

    expect(transport.configPath, endsWith('/backend/config/config.json'));
    expect(transport.poolPath, endsWith('/backend/config/device_pool.json'));
    expect(transport.filterPath, endsWith('/backend/config/filter.json'));
    expect(transport.runtimeDir, endsWith('/backend'));
    await backend.stop();
  });
}

/// A [RustBackendTransport] with the FFI calls replaced by counters, so the
/// lifecycle can be verified without loading the shared library.
class _FakeRustTransport extends RustBackendTransport {
  _FakeRustTransport({
    this.initResult = 'running',
    this.healthy = true,
    this.blockStop = false,
  });

  String initResult;
  bool healthy;
  final bool blockStop;

  int initCalls = 0;
  int stopCalls = 0;
  int healthChecks = 0;
  String? configPath;
  String? poolPath;
  String? filterPath;
  String? runtimeDir;

  final stopEntered = Completer<void>();
  final allowStop = Completer<void>();

  @override
  String get baseUrl => 'http://127.0.0.1:8080';

  @override
  Future<String> start({
    required String configPath,
    required String poolPath,
    required String filterPath,
    required String runtimeDir,
  }) async {
    initCalls += 1;
    this.configPath = configPath;
    this.poolPath = poolPath;
    this.filterPath = filterPath;
    this.runtimeDir = runtimeDir;
    return initResult;
  }

  @override
  Future<String> status() async => 'running';

  @override
  Future<void> stop() async {
    stopCalls += 1;
    if (blockStop) {
      if (!stopEntered.isCompleted) stopEntered.complete();
      await allowStop.future;
    }
  }

  @override
  Future<BackendResponse> send(
    String method,
    Uri url, {
    Uint8List? body,
    Duration? timeout,
    BackendRequest? request,
  }) async {
    if (url.path == '/health') {
      healthChecks += 1;
      if (!healthy) throw const SocketException('backend down');
      return BackendResponse(200, Uint8List(0), 'application/json');
    }
    return BackendResponse(404, Uint8List(0), 'application/json');
  }
}

class _BackendAssets extends CachingAssetBundle {
  _BackendAssets({this.blockFirstLoad = false});

  final bool blockFirstLoad;
  final loadEntered = Completer<void>();
  final allowLoad = Completer<void>();
  static const runtimeAssets = [
    'assets/filters/book.js',
    'assets/web/index.html',
    'assets/web/assets/css/all.min.css',
    'assets/web/assets/webfonts/fa-solid-900.woff2',
    'assets/plugins/player.html',
  ];

  @override
  Future<ByteData> load(String key) async {
    if (!loadEntered.isCompleted) {
      loadEntered.complete();
      if (blockFirstLoad) await allowLoad.future;
    }
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({
        for (final path in runtimeAssets)
          path: [
            {'asset': path},
          ],
      })!;
    }
    return ByteData.sublistView(Uint8List.fromList([123, 125]));
  }
}
