import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/backend_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fqapp/backend');
  late Directory directory;
  late HttpServer server;
  late BackendService backend;
  late List<String> nativeCalls;
  Completer<void>? stopEntered;
  Completer<void>? allowStop;
  HttpOverrides? previousHttpOverrides;

  BackendService createBackend({
    AssetBundle? assets,
    Duration timeout = const Duration(seconds: 2),
    Duration shutdownTimeout = const Duration(seconds: 3),
    bool useJni = true,
    BackendProcessStarter? startProcess,
  }) => BackendService(
    assets: assets ?? _BackendAssets(),
    supportDirectory: () async => directory,
    useJni: useJni,
    startProcess: startProcess,
    baseUrl: 'http://127.0.0.1:${server.port}',
    startupTimeout: timeout,
    shutdownTimeout: shutdownTimeout,
  );

  setUp(() async {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp('fqapp_backend_test_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    nativeCalls = [];
    stopEntered = null;
    allowStop = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      nativeCalls.add(call.method);
      if (call.method == 'startBackend') return 'running';
      if (call.method == 'stopBackend') {
        if (stopEntered?.isCompleted == false) stopEntered!.complete();
        await allowStop?.future;
      }
      return null;
    });
    backend = createBackend();
  });

  tearDown(() async {
    if (allowStop?.isCompleted == false) allowStop!.complete();
    await backend.stop();
    await server.close(force: true);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
    HttpOverrides.global = previousHttpOverrides;
  });

  for (final succeeds in [true, false]) {
    test(
      'concurrent starts share the final ${succeeds ? 'success' : 'failure'}',
      () async {
        backend = createBackend(timeout: const Duration(milliseconds: 300));
        final received = Completer<HttpRequest>();
        server.listen((request) {
          if (!received.isCompleted) {
            received.complete(request);
          } else {
            request.response.statusCode = 503;
            request.response.close().ignore();
          }
        });

        final first = backend.start();
        final request = await received.future;
        // The JNI call has finished; startup still owns the health check.
        final second = backend.start();
        expect(identical(first, second), isTrue);
        final result = succeeds
            ? Future.wait([first, second])
            : Future.wait([
                expectLater(first, throwsStateError),
                expectLater(second, throwsStateError),
              ]);

        request.response.statusCode = succeeds ? 200 : 503;
        await request.response.close();
        await result;
        expect(backend.isRunning, succeeds);
        expect(
          nativeCalls.where((call) => call == 'startBackend'),
          hasLength(1),
        );
      },
    );
  }

  for (final sendsHeaders in [false, true]) {
    test(
      'startup times out when health ${sendsHeaders ? 'body' : 'headers'} stall',
      () async {
        backend = createBackend(timeout: const Duration(milliseconds: 200));
        var received = false;
        server.listen((request) {
          received = true;
          request.response.done.ignore();
          if (sendsHeaders) {
            request.response.contentLength = 100;
            request.response.write('x');
            request.response.flush().ignore();
          }
        });

        await expectLater(
          backend.start().timeout(const Duration(seconds: 2)),
          throwsStateError,
        );
        expect(received, isTrue);
        expect(backend.isRunning, isFalse);
        expect(nativeCalls, contains('stopBackend'));
      },
    );
  }

  test(
    'stop during deployment waits and shuts down the created backend',
    () async {
      final assets = _BackendAssets(blockFirstLoad: true);
      backend = createBackend(assets: assets);
      server.listen((request) => request.response.close().ignore());

      final starting = backend.start();
      await assets.loadEntered.future;
      final stopping = backend.stop();
      assets.allowLoad.complete();
      await starting;
      await stopping;

      expect(nativeCalls, ['startBackend', 'stopBackend']);
      expect(backend.isRunning, isFalse);
    },
  );

  test('a start during shutdown waits and launches a new backend', () async {
    server.listen((request) => request.response.close().ignore());
    await backend.start();
    stopEntered = Completer<void>();
    allowStop = Completer<void>();
    final stopping = backend.stop();
    await stopEntered!.future;

    final restarting = backend.start();
    expect(nativeCalls, ['startBackend', 'stopBackend']);
    allowStop!.complete();
    await stopping;
    await restarting;

    expect(nativeCalls, ['startBackend', 'stopBackend', 'startBackend']);
    expect(backend.isRunning, isTrue);
  });

  test('restart queues behind a stop that is waiting for deployment', () async {
    final assets = _BackendAssets(blockFirstLoad: true);
    backend = createBackend(assets: assets);
    server.listen((request) => request.response.close().ignore());

    final starting = backend.start();
    await assets.loadEntered.future;
    final stopping = backend.stop();
    final restarting = backend.start();
    assets.allowLoad.complete();
    await starting;
    await stopping;
    await restarting;

    expect(nativeCalls, ['startBackend', 'stopBackend', 'startBackend']);
    expect(backend.isRunning, isTrue);
  });

  test(
    'deploys nested runtime assets and keeps the registered device pool',
    () async {
      server.listen((request) => request.response.close().ignore());
      await backend.start();
      for (final path in _BackendAssets.runtimeAssets) {
        final file = File(
          '${directory.path}/backend/${path.substring('assets/'.length)}',
        );
        expect(await file.readAsString(), '{}', reason: path);
      }
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
    },
  );

  test(
    'desktop stop forces an unresponsive process to exit before restart',
    () async {
      final processes = <_BackendProcess>[];
      backend = createBackend(
        useJni: false,
        shutdownTimeout: const Duration(milliseconds: 30),
        startProcess: (_, arguments, {workingDirectory}) async {
          expect(
            processes.every((process) => process.exited.isCompleted),
            isTrue,
          );
          expect(arguments, contains('-runtime-dir'));
          final process = _BackendProcess(ignoreTerm: true);
          processes.add(process);
          return process;
        },
      );
      server.listen((request) => request.response.close().ignore());

      await backend.start();
      await backend.stop();
      expect(processes.single.signals, [
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]);
      expect(processes.single.exited.isCompleted, isTrue);
      expect(backend.isRunning, isFalse);
      await backend.start();
      expect(processes, hasLength(2));
      expect(backend.isRunning, isTrue);
    },
  );

  test('desktop startup failure releases its process before a retry', () async {
    final processes = <_BackendProcess>[];
    var healthy = false;
    backend = createBackend(
      useJni: false,
      timeout: const Duration(milliseconds: 100),
      shutdownTimeout: const Duration(milliseconds: 30),
      startProcess: (_, _, {workingDirectory}) async {
        expect(
          processes.every((process) => process.exited.isCompleted),
          isTrue,
        );
        final process = _BackendProcess(ignoreTerm: true);
        processes.add(process);
        return process;
      },
    );
    server.listen((request) {
      request.response.statusCode = healthy ? 200 : 503;
      request.response.close().ignore();
    });

    await expectLater(backend.start(), throwsStateError);
    expect(processes.single.exited.isCompleted, isTrue);
    healthy = true;
    await backend.start();
    expect(processes, hasLength(2));
  });

  test(
    'a failed desktop shutdown retains the process for another stop',
    () async {
      final process = _BackendProcess(ignoredSignals: 2);
      backend = createBackend(
        useJni: false,
        shutdownTimeout: const Duration(milliseconds: 30),
        startProcess: (_, _, {workingDirectory}) async => process,
      );
      server.listen((request) => request.response.close().ignore());

      await backend.start();
      await expectLater(backend.stop(), throwsA(isA<TimeoutException>()));
      expect(backend.isRunning, isTrue);
      await backend.stop();
      expect(process.exited.isCompleted, isTrue);
      expect(backend.isRunning, isFalse);
    },
  );

  test('desktop UTF-8 and malformed logs cannot fail startup', () async {
    final process = _BackendProcess();
    backend = createBackend(
      useJni: false,
      startProcess: (_, _, {workingDirectory}) async => process,
    );
    server.listen((request) => request.response.close().ignore());

    await backend.start();
    process.output.add(utf8.encode('本地后端已就绪\n'));
    process.output.add([255, 10]);
    process.errors.addError(StateError('log pipe failed'));
    await Future<void>.delayed(Duration.zero);

    expect(backend.logLines, contains('本地后端已就绪'));
    expect(backend.logLines, contains('\uFFFD'));
    expect(
      backend.logLines.any((line) => line.contains('log pipe failed')),
      isTrue,
    );
  });
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

class _BackendProcess implements Process {
  _BackendProcess({this.ignoreTerm = false, this.ignoredSignals = 0});

  final bool ignoreTerm;
  int ignoredSignals;
  final exited = Completer<int>();
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final signals = <ProcessSignal>[];

  @override
  int get pid => 42;

  @override
  Future<int> get exitCode => exited.future;

  @override
  Stream<List<int>> get stdout => output.stream;

  @override
  Stream<List<int>> get stderr => errors.stream;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (ignoredSignals > 0) {
      ignoredSignals -= 1;
      return false;
    }
    if (ignoreTerm && signal == ProcessSignal.sigterm) return true;
    if (!exited.isCompleted) {
      exited.complete(0);
      output.close().ignore();
      errors.close().ignore();
    }
    return true;
  }
}
