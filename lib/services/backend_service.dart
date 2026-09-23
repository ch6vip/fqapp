import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'backend_transport.dart';

/// Manages the local backend core.
///
/// The backend is the Rust native core (`rust/`, packaged as
/// `libfqapi_core.so`). Flutter calls it over flutter_rust_bridge; the same
/// Rust core also serves the built-in Web UI and `/src/*` resources over a
/// loopback HTTP adapter, which is why [baseUrl] still exists for resource
/// resolution in `ApiClient.absoluteUrl`.
///
/// There is no process to launch and no JNI bridge: `start` deploys the
/// runtime files and initializes the core in-process.
class BackendService {
  BackendService({
    AssetBundle? assets,
    Future<Directory> Function()? supportDirectory,
    BackendTransport? transport,
    this.fallbackBaseUrl = 'http://127.0.0.1:8080',
    this.startupTimeout = const Duration(seconds: 15),
    this.shutdownTimeout = const Duration(seconds: 3),
  }) : _assets = assets ?? rootBundle,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _transport = transport ?? RustBackendTransport();

  static final BackendService instance = BackendService();

  final AssetBundle _assets;
  final Future<Directory> Function() _supportDirectory;
  final BackendTransport _transport;

  /// Used for resource URLs only when the core has not reported a port yet.
  final String fallbackBaseUrl;

  final Duration startupTimeout;
  final Duration shutdownTimeout;

  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  bool _running = false;
  /// Whether this service successfully initialized the core, so [stop] only
  /// tears down something it created.
  bool _coreStarted = false;
  final List<String> _logLines = [];
  File? _logFile;
  // Serializes async log-file writes so concurrent appends don't interleave.
  Future<void> _logWriteQueue = Future.value();

  /// The transport business calls go through.
  BackendTransport get transport => _transport;

  /// Base URL used to resolve backend-relative resources.
  String get baseUrl =>
      _transport.baseUrl.isNotEmpty ? _transport.baseUrl : fallbackBaseUrl;

  /// Whether the Rust FFI transport is in use (as opposed to the HTTP adapter).
  bool get usesRustTransport => _transport is RustBackendTransport;

  /// Whether the backend core is currently running.
  bool get isRunning => _running;

  /// Recent backend log lines (for diagnostics).
  List<String> get logLines => List.unmodifiable(_logLines);

  /// Path of the directory where backend files live.
  Future<Directory> _backendDir() async {
    final dir = await _supportDirectory();
    final backend = Directory('${dir.path}/backend');
    if (!await backend.exists()) {
      await backend.create(recursive: true);
    }
    return backend;
  }

  /// Copies an asset bundle entry to [dest] if missing or stale.
  Future<void> _copyAsset(String assetPath, File dest) async {
    final data = await _assets.load(assetPath);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (await _hasSameBytes(dest, bytes)) return;

    await dest.parent.create(recursive: true);
    final temporary = File('${dest.path}.asset-tmp');
    if (await temporary.exists()) await temporary.delete();
    await temporary.writeAsBytes(bytes, flush: true);
    try {
      await temporary.rename(dest.path);
    } on FileSystemException {
      if (await dest.exists()) await dest.delete();
      await temporary.rename(dest.path);
    }
  }

  Future<bool> _hasSameBytes(File file, Uint8List bundled) async {
    if (!await file.exists() || await file.length() != bundled.length) {
      return false;
    }
    final existing = await file.readAsBytes();
    if (bundled.length < 256 * 1024) return _bytesEqual(existing, bundled);
    return Isolate.run(() => _bytesEqual(existing, bundled));
  }

  /// Deploys the runtime files the Rust core reads (config + Web/静态资源)。
  Future<void> _deploy() async {
    final dir = await _backendDir();

    final configDir = Directory('${dir.path}/config');
    await configDir.create(recursive: true);

    await _copyAsset(
      'assets/config/config.json',
      File('${dir.path}/config/config.json'),
    );
    await _copyAsset(
      'assets/config/device_pool.example.json',
      File('${dir.path}/config/device_pool.example.json'),
    );
    await _copyAsset(
      'assets/config/filter.json',
      File('${dir.path}/config/filter.json'),
    );
    // Seed the device pool from the example on first launch (the core
    // registers a real device on demand and persists it here).
    final poolFile = File('${dir.path}/config/device_pool.json');
    if (!await poolFile.exists()) {
      await _copyAsset('assets/config/device_pool.example.json', poolFile);
    }

    // Use the bundle manifest so nested CSS/fonts and plugin files are
    // deployed along with the top-level HTML and filters.
    const runtimeRoots = ['assets/filters/', 'assets/web/', 'assets/plugins/'];
    final manifest = await AssetManifest.loadFromAssetBundle(_assets);
    for (final asset in manifest.listAssets()) {
      if (runtimeRoots.any(asset.startsWith)) {
        final relative = asset.substring('assets/'.length);
        await _copyAsset(asset, File('${dir.path}/$relative'));
      }
    }
  }

  void _log(String line) {
    _logLines.add(line);
    if (_logLines.length > 500) _logLines.removeAt(0);
    final file = _logFile;
    if (file == null) return;
    _logWriteQueue = _logWriteQueue.then((_) async {
      try {
        await file.writeAsString('$line\n', mode: FileMode.append);
      } catch (_) {}
    });
  }

  /// Starts the backend if not already running.
  ///
  /// Concurrent callers share the same startup future, so every caller waits
  /// for a definitive healthy/error result. Initialization is idempotent: a
  /// second call while running returns immediately.
  Future<void> start() {
    final stopping = _stopFuture;
    if (stopping != null) return stopping.then((_) => start());
    final active = _startFuture;
    if (active != null) return active;
    late final Future<void> tracked;
    tracked = _startInternal().whenComplete(() {
      if (identical(_startFuture, tracked)) _startFuture = null;
    });
    _startFuture = tracked;
    return tracked;
  }

  Future<void> _startInternal() async {
    try {
      if (_running) return;
      await _deploy();
      final dir = await _backendDir();

      // Reset the log file each start.
      final logPath = '${dir.path}/backend.log';
      await _logWriteQueue;
      try {
        File(logPath).deleteSync();
      } catch (_) {}
      _logFile = File(logPath);

      final rustTransport = _transport;
      if (rustTransport is RustBackendTransport) {
        _log('initializing Rust core...');
        final result = await rustTransport.start(
          configPath: '${dir.path}/config/config.json',
          poolPath: '${dir.path}/config/device_pool.json',
          filterPath: '${dir.path}/config/filter.json',
          runtimeDir: dir.path,
        );
        _log('Rust core init returned: $result');
        if (result != 'running') {
          throw StateError('Rust core failed: $result');
        }
        _coreStarted = true;
      }

      final ok = await _waitHealthy(startupTimeout);
      if (!ok) {
        await _stopRunningBackend();
        throw StateError(
          'backend failed to start (health check timeout)\n'
          'logs: ${_logLines.join('\n')}',
        );
      }
      _running = true;
      _log('backend healthy');
    } catch (e) {
      _log('start error: $e');
      rethrow;
    }
  }

  /// Polls `/health` until the backend responds or [timeout] elapses.
  Future<bool> _waitHealthy(Duration timeout) async {
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < timeout) {
      final remaining = timeout - elapsed.elapsed;
      final attemptTimeout = remaining < const Duration(seconds: 2)
          ? remaining
          : const Duration(seconds: 2);
      if (attemptTimeout <= Duration.zero) break;
      try {
        final response = await _transport.send(
          'GET',
          Uri.parse('$baseUrl/health'),
          timeout: attemptTimeout,
        );
        if (response.statusCode == 200) return true;
        _log('health check: HTTP ${response.statusCode}');
      } catch (_) {
        // Not up yet. Bound the complete exchange, including body reading.
      }
      final pause = timeout - elapsed.elapsed;
      if (pause <= Duration.zero) break;
      await Future<void>.delayed(
        pause < const Duration(milliseconds: 300)
            ? pause
            : const Duration(milliseconds: 300),
      );
    }
    return false;
  }

  /// Stops the backend core. Safe to call repeatedly.
  Future<void> stop() {
    final active = _stopFuture;
    if (active != null) return active;
    late final Future<void> tracked;
    tracked = _stopInternal().whenComplete(() {
      if (identical(_stopFuture, tracked)) _stopFuture = null;
    });
    _stopFuture = tracked;
    return tracked;
  }

  Future<void> _stopInternal() async {
    // Startup can still be in flight when stop() is called; wait for that
    // attempt before stopping the resource it owns.
    try {
      await _startFuture;
    } catch (_) {
      // A failed start performs its own cleanup.
    }
    try {
      await _stopRunningBackend();
    } finally {
      await _logWriteQueue;
    }
  }

  Future<void> _stopRunningBackend() async {
    final transport = _transport;
    if (_coreStarted && transport is RustBackendTransport) {
      _coreStarted = false;
      try {
        await transport.stop().timeout(shutdownTimeout);
      } catch (e) {
        _log('shutdown failed: $e');
      }
    }
    _running = false;
  }
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
