import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/backend_service.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/src/rust/api.dart' as rust;
import 'package:fqapp/src/rust/frb_generated.dart';

/// Real Dart -> flutter_rust_bridge -> Rust integration against the host build
/// of the core, with a local mock upstream. No network, no device, no real
/// device pool: every fixture is created in a temporary directory.
///
/// Run it through `scripts/run_rust_host_tests.ps1` (or `.sh`), which builds
/// the host cdylib first. When the library is absent these tests are reported
/// as SKIPPED, never as passed - the Android ARM64 library is only verified on
/// a device.

String hostLibraryPath() {
  final override = Platform.environment['FQAPP_RUST_HOST_LIB'];
  if (override != null && override.isNotEmpty) return override;
  final name = Platform.isWindows
      ? 'fqapi_core.dll'
      : Platform.isMacOS
      ? 'libfqapi_core.dylib'
      : 'libfqapi_core.so';
  return 'rust/target/debug/$name';
}

/// Five pooled devices: enough that no endpoint triggers registration, so the
/// tests never need network access or a real device pool.
String pooledDevicesJson() => jsonEncode({
  'android': [
    for (var i = 0; i < 5; i++)
      {
        'device_id': i.toString().padLeft(16, '0'),
        'install_id': '${9000000000000000000 + i}',
        'secret_key': i.toRadixString(16).padLeft(32, '0'),
        'platform': 'android',
        'status': 'active',
        'created_time': '2026-01-01 00:00:00',
        'last_used': '2026-01-01 00:00:0$i',
        'use_count': i,
        'cdid': 'cdid-$i',
      },
  ],
  'last_update': '2026-01-01 00:00:00',
});

void main() {
  final libraryPath = hostLibraryPath();
  final skipReason = File(libraryPath).existsSync()
      ? null
      : 'host Rust core not built at $libraryPath; run '
            'scripts/run_rust_host_tests.ps1 (or .sh) first';

  late HttpServer mock;
  late String mockOrigin;
  late Directory root;
  final mockRequests = <Uri>[];
  Duration mockDelay = Duration.zero;
  String mockPayload = '{"code":0,"data":{"served_by":"mock-upstream"}}';

  setUpAll(() async {
    if (skipReason != null) return;
    await RustLib.init(externalLibrary: ExternalLibrary.open(libraryPath));
    // Tell the transport the process-wide runtime is up, so its own
    // idempotent loader does not try to initialize the bridge a second time.
    RustBackendTransport.markRuntimeReady();
    mock = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mockOrigin = 'http://127.0.0.1:${mock.port}';
    mock.listen((request) async {
      mockRequests.add(request.uri);
      final delay = mockDelay;
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(mockPayload);
      await request.response.close();
    });
  });

  tearDownAll(() async {
    if (skipReason != null) return;
    await mock.close(force: true);
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('fqapp-rust-host-');
    Directory('${root.path}/config').createSync(recursive: true);
    Directory('${root.path}/src').createSync(recursive: true);
    File('${root.path}/config/config.json').writeAsStringSync(
      '{"algorithm_type":"8404","port":0,"anti_crawler":{"enabled":false,"redirect_url":""}}',
    );
    File('${root.path}/config/device_pool.json')
        .writeAsStringSync(pooledDevicesJson());
    File('${root.path}/src/ok.txt').writeAsStringSync('0123456789');
    File('${root.path}/outside.txt').writeAsStringSync('OFFLINE_TEST_MARKER');
    mockRequests.clear();
    mockDelay = Duration.zero;
    mockPayload = '{"code":0,"data":{"served_by":"mock-upstream"}}';
  });

  tearDown(() async {
    await rust.shutdown();
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // A dropped handle must not turn a passing test red.
    }
  });

  Future<String> startCore({String? origin, int port = 0}) => rust.init(
    configPath: '${root.path}/config/config.json',
    poolPath: '${root.path}/config/device_pool.json',
    filterPath: '${root.path}/config/filter.json',
    runtimeDir: root.path,
    port: port,
    mockUpstreamOrigin: origin ?? mockOrigin,
  );

  String bodyOf(rust.BridgeResponse response) =>
      utf8.decode(response.body, allowMalformed: true);

  Future<ApiClient> startApiClient() async {
    final transport = RustBackendTransport(
      port: 0,
      mockUpstreamOrigin: mockOrigin,
    );
    addTearDown(transport.close);
    expect(
      await transport.start(
        configPath: '${root.path}/config/config.json',
        poolPath: '${root.path}/config/device_pool.json',
        filterPath: '${root.path}/config/filter.json',
        runtimeDir: root.path,
      ),
      'running',
    );
    return ApiClient(transport: transport);
  }

  test('the real FFI path initializes, serves static files and reaches upstream',
      () async {
    final started = await startCore();
    expect(started, 'running');
    expect(await rust.status(), 'running');
    expect(await rust.baseUrl(), startsWith('http://127.0.0.1:'));

    // /health is answered by the Rust core with no upstream involvement.
    final health = await rust.request(
      requestId: 'host-health',
      method: 'GET',
      path: '/health',
      query: '',
      body: Uint8List(0),
      timeoutMs: 0,
    );
    expect(health.status, 200);
    expect(jsonDecode(bodyOf(health))['status'], 'ok');

    // Static file served over FFI (the body is materialised by the core).
    final file = await rust.request(
      requestId: 'host-file',
      method: 'GET',
      path: '/src/ok.txt',
      query: '',
      body: Uint8List(0),
      timeoutMs: 0,
    );
    expect(file.status, 200);
    expect(bodyOf(file), '0123456789');

    // Path confinement holds on the FFI path too.
    final escaped = await rust.request(
      requestId: 'host-escape',
      method: 'GET',
      path: '/src/../outside.txt',
      query: '',
      body: Uint8List(0),
      timeoutMs: 0,
    );
    expect(escaped.status, 404);
    expect(bodyOf(escaped), isNot(contains('OFFLINE_TEST_MARKER')));

    // A business request really goes through the dispatcher to the upstream
    // (redirected to the local mock by mockUpstreamOrigin).
    final items = await rust.request(
      requestId: 'host-items',
      method: 'GET',
      path: '/api/v1/items/7507512821328904729',
      query: '',
      body: Uint8List(0),
      timeoutMs: 0,
    );
    expect(items.status, 200);
    expect(jsonDecode(bodyOf(items))['data']['served_by'], 'mock-upstream');
    expect(mockRequests, isNotEmpty);
    expect(mockRequests.last.path, '/api/novel/book/directory/detail/v/');
    expect(mockRequests.last.queryParameters['item_ids'],
        '7507512821328904729');
  }, skip: skipReason);

  test('cancelling an in-flight FFI request aborts it promptly', () async {
    await startCore();
    mockDelay = const Duration(milliseconds: 800);

    final stopped = Stopwatch()..start();
    final pending = rust.request(
      requestId: 'cancel-me',
      method: 'GET',
      path: '/api/v1/items/7507512821328904729',
      query: '',
      body: Uint8List(0),
      timeoutMs: 0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(await rust.cancel(requestId: 'cancel-me'), isTrue);

    final response = await pending.timeout(const Duration(seconds: 5));
    stopped.stop();
    expect(response.status, 499, reason: 'cancelled, not published');
    expect(
      stopped.elapsed,
      lessThan(const Duration(seconds: 3)),
      reason: 'the in-flight upstream call must be torn down, not awaited',
    );
  }, skip: skipReason);

  test('a deadline is reported separately from a cancellation', () async {
    await startCore();
    mockDelay = const Duration(milliseconds: 800);

    final stopped = Stopwatch()..start();
    final response = await rust.request(
      requestId: 'timeout-me',
      method: 'GET',
      path: '/api/v1/items/7507512821328904729',
      query: '',
      body: Uint8List(0),
      timeoutMs: 150,
    );
    stopped.stop();
    expect(response.status, 504);
    expect(stopped.elapsed, lessThan(const Duration(seconds: 3)));
    // Nothing is left registered for that id.
    expect(await rust.cancel(requestId: 'timeout-me'), isFalse);
  }, skip: skipReason);

  test('shutdown and restart produce a working core again', () async {
    expect(await startCore(), 'running');
    final firstBase = await rust.baseUrl();
    final beforeRestart = await rust.request(
      requestId: 'before-restart',
      method: 'GET',
      path: '/health',
      query: '',
      body: Uint8List(0),
      timeoutMs: 0,
    );
    expect(beforeRestart.status, 200);

    await rust.shutdown();
    expect(await rust.status(), 'starting');
    expect(await rust.baseUrl(), isEmpty);

    expect(await startCore(), 'running');
    expect(await rust.baseUrl(), startsWith('http://127.0.0.1:'));
    final afterRestart = await rust.request(
      requestId: 'after-restart',
      method: 'GET',
      path: '/health',
      query: '',
      body: Uint8List(0),
      timeoutMs: 0,
    );
    expect(afterRestart.status, 200);
    expect(firstBase, isNotEmpty);
  }, skip: skipReason);

  test('codec rejection cannot become a source through Dart legacy parsing',
      () async {
    mockPayload = jsonEncode(_videoPayload());
    await startCore();
    final response = await rust.request(
      requestId: 'host-video-codec-rejected',
      method: 'GET',
      path: '/api/v1/videos/episode',
      query: 'mode=stream',
      body: Uint8List(0),
      timeoutMs: 0,
    );
    final payload = jsonDecode(bodyOf(response)) as Map<String, dynamic>;
    expect(
      () => EpisodeSource.fromResponse(payload),
      throwsA(isA<ApiException>()),
    );
    expect(response.status, 500);
    expect(bodyOf(response), isNot(contains('https://example.invalid/')));
  }, skip: skipReason);

  test('ApiClient reports codec rejection before creating an episode source',
      () async {
    mockPayload = jsonEncode(_videoPayload());
    final api = await startApiClient();
    await expectLater(
      api.content('episode', tab: '短剧', mode: 'stream'),
      throwsA(isA<ApiException>().having(
        (error) => error.message,
        'message',
        '该视频暂不支持播放',
      )),
    );
  }, skip: skipReason);

  test('a mixed video response keeps the allowed URL and its content key',
      () async {
    mockPayload = jsonEncode(_videoPayload(includeH264: true));
    final api = await startApiClient();
    final payload = await api.content('episode', tab: '短剧', mode: 'stream');
    final source = EpisodeSource.fromResponse(payload);
    expect(source.url, 'https://example.invalid/h264.mp4');
    expect(source.keyHex, '4990a92de837e29e18031a370ab744e6');
    expect(jsonEncode(payload), isNot(contains('bytevc2.mp4')));
  }, skip: skipReason);

  test('an unrecognized legacy video response still reaches Dart parsing',
      () async {
    mockPayload = jsonEncode({
      'code': 0,
      'data': {
        'legacy': {'main_url': 'https://example.invalid/legacy.mp4'},
      },
    });
    final api = await startApiClient();
    final payload = await api.content('episode', tab: '短剧', mode: 'stream');
    final source = EpisodeSource.fromResponse(payload);
    expect(source.url, 'https://example.invalid/legacy.mp4');
    expect(source.keyHex, isEmpty);
  }, skip: skipReason);

  test('BackendService and ApiClient work end to end over the real core',
      () async {
    mockPayload =
        '{"code":0,"data":{"search_tabs":[{"title":"书籍","data":[]}]}}';
    final backend = BackendService(
      assets: _HostAssets(pooledDevicesJson()),
      supportDirectory: () async => root,
      transport: RustBackendTransport(mockUpstreamOrigin: mockOrigin),
      startupTimeout: const Duration(seconds: 10),
    );
    await backend.start();
    expect(backend.isRunning, isTrue);
    expect(backend.usesRustTransport, isTrue);

    final api = ApiClient(transport: backend.transport);
    expect(await api.health(), isTrue);

    final search = await api.search('测试');
    expect(search['code'], 200);
    expect((search['data'] as Map)['search_tabs'], isA<List>());
    expect(mockRequests, isNotEmpty);

    await backend.stop();
    expect(backend.isRunning, isFalse);
  }, skip: skipReason);
}

Map<String, dynamic> _videoPayload({bool includeH264 = false}) => {
      'code': 0,
      'data': {
        'video_model': {
          'key_seed': 'AAAA',
          'video_list': {
            'video_1': {
              'main_url': 'https://example.invalid/bytevc2.mp4',
              'codec_type': 'bytevc2',
              'vwidth': 1080,
            },
            if (includeH264)
              'video_2': {
                'main_url': 'https://example.invalid/h264.mp4',
                'codec_type': 'h264',
                'vwidth': 720,
                'spade_a':
                    'kbwf80+1N+V9nwHQSp431GWvLeBlqizTYJ0o5FOrHuZhqimysg==',
              },
          },
        },
      },
    };

/// Minimal bundle so BackendService's deployment step has real files to copy.
class _HostAssets extends CachingAssetBundle {
  _HostAssets(this.poolJson);

  final String poolJson;

  Map<String, String> get _contents => <String, String>{
    'assets/config/config.json':
        '{"algorithm_type":"8404","port":0,"anti_crawler":{"enabled":false,"redirect_url":""}}',
    'assets/config/device_pool.example.json': poolJson,
    'assets/config/filter.json': '{"routes":{}}',
    'assets/web/index.html': '<html></html>',
  };

  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({
        for (final path in _contents.keys)
          path: [
            {'asset': path},
          ],
      })!;
    }
    final contents = _contents[key];
    if (contents == null) {
      throw StateError('unexpected asset request: $key');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(contents)));
  }
}
