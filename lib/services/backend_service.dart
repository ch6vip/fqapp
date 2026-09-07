import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef BackendProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

/// Manages the local Go  backend.
///
/// On Android the backend ships as liblegacy.so (a real c-shared library with
/// JNI exports) and is started via a MethodChannel → Kotlin → JNI path. The
/// standalone executable is deployed only on desktop; Android cannot execute
/// app-data binaries under SELinux and therefore uses the JNI backend only.
class BackendService {
  BackendService({
    AssetBundle? assets,
    Future<Directory> Function()? supportDirectory,
    bool? useJni,
    BackendProcessStarter? startProcess,
    this.baseUrl = 'http://127.0.0.1:8080',
    this._startupTimeout = const Duration(seconds: 15),
    this._shutdownTimeout = const Duration(seconds: 3),
  }) : _assets = assets ?? rootBundle,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _useJni = useJni ?? (!kIsWeb && Platform.isAndroid),
       _startProcess = startProcess ?? Process.start;

  static final BackendService instance = BackendService();

  static const MethodChannel _channel = MethodChannel('fqapp/backend');
  final AssetBundle _assets;
  final Future<Directory> Function() _supportDirectory;
  final bool _useJni;
  final BackendProcessStarter _startProcess;
  final Duration _startupTimeout;
  final Duration _shutdownTimeout;

  Process? _proc;
  bool _viaJni = false;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  final List<StreamSubscription<String>> _logSubs = [];
  final List<String> _logLines = [];
  File? _logFile;
  // Serializes async log-file writes so concurrent appends don't interleave.
  Future<void> _logWriteQueue = Future.value();

  /// Base URL of the local backend.
  final String baseUrl;

  /// Whether the backend is currently running (via JNI or as a subprocess).
  bool get isRunning => _viaJni || (_proc != null && _proc!.pid > 0);

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
      // rename() replaces an existing regular file atomically on Android and
      // the supported desktop filesystems.
      await temporary.rename(dest.path);
    } on FileSystemException {
      // Some Windows filesystems do not replace an existing destination.
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

  /// Deploys the backend binary + runtime files from assets to disk.
  Future<void> _deploy({required bool includeExecutable}) async {
    final dir = await _backendDir();

    if (includeExecutable) {
      final bin = File('${dir.path}/');
      await _copyAsset('assets/bin/', bin);
      try {
        await Process.run('chmod', ['755', bin.path]);
      } catch (_) {
        // Windows has no chmod; executable permissions are not needed there.
      }
    }

    // Config
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
    // Seed the device pool from the example on first launch (the backend
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
    // Append to a file for offline diagnosis without blocking the UI isolate.
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
  /// for a definitive healthy/error result.
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
      if (_viaJni || _proc != null) {
        if (await _waitHealthy(_startupTimeout)) return;
        await _stopRunningBackend();
      }
      await _cancelLogSubscriptions();
      final android = _useJni;
      await _deploy(includeExecutable: !android);
      final dir = await _backendDir();

      // Reset log file each start.
      final logPath = '${dir.path}/backend.log';
      await _logWriteQueue;
      try {
        File(logPath).deleteSync();
      } catch (_) {}
      _logFile = File(logPath);

      // --- JNI path (Android only) ---
      if (android) {
        try {
          _log('trying JNI backend (liblegacy.so)...');
          final result = await _channel
              .invokeMethod<String>('startBackend', {
                'config': '${dir.path}/config/config.json',
                'pool': '${dir.path}/config/device_pool.json',
                'filter': '${dir.path}/config/filter.json',
              })
              .timeout(const Duration(seconds: 20));
          _log('JNI startBackend returned: $result');
          if (result == 'running') {
            _viaJni = true;
            final ok = await _waitHealthy(_startupTimeout);
            if (!ok) {
              throw StateError(
                'JNI backend started but /health did not come up',
              );
            }
            _log('JNI backend healthy');
            return;
          }
          throw StateError('JNI backend failed: $result');
        } catch (e) {
          _viaJni = false;
          _log('JNI path failed: $e');
          try {
            await _channel
                .invokeMethod('stopBackend')
                .timeout(_shutdownTimeout);
          } catch (stopError) {
            _log('stop failed JNI backend failed: $stopError');
          }
          rethrow;
        }
      }

      // --- Desktop Process.start path ---
      final bin = '${dir.path}/';
      _log('starting backend via Process.start: $bin');
      _log('workdir: ${dir.path}');

      _proc = await _startProcess(bin, [
        '-config',
        '${dir.path}/config/config.json',
        '-pool',
        '${dir.path}/config/device_pool.json',
        '-filter',
        '${dir.path}/config/filter.json',
        '-runtime-dir',
        dir.path,
      ], workingDirectory: dir.path);
      final process = _proc!;
      _log('backend pid: ${process.pid}');

      // Drain stdout/stderr so the child never blocks on a full pipe.
      final stdoutLines = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
      _logSubs.add(
        stdoutLines.listen(
          _log,
          onError: (Object error) => _log('backend stdout error: $error'),
        ),
      );
      final stderrLines = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
      _logSubs.add(
        stderrLines.listen(
          _log,
          onError: (Object error) => _log('backend stderr error: $error'),
        ),
      );
      process.exitCode.then((code) {
        _log('backend exited with code $code');
        if (identical(_proc, process)) _proc = null;
      });

      // Wait for the health endpoint to come up.
      final ok = await _waitHealthy(_startupTimeout);
      if (!ok) {
        // Do not release the process until it has exited; retries must not
        // overwrite its executable or race an old listener for the same port.
        await _stopRunningBackend();
        await _cancelLogSubscriptions();
        throw StateError(
          ' backend failed to start (health check timeout)\n'
          'logs: ${_logLines.join('\n')}',
        );
      }
      _log('backend healthy');
    } catch (e) {
      _log('start error: $e');
      rethrow;
    }
  }

  /// Polls /health until the backend responds or [timeout] elapses.
  Future<bool> _waitHealthy(Duration timeout) async {
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < timeout) {
      // If the process died and we're not on the JNI path, give up.
      if (!_viaJni && _proc == null) return false;
      final remaining = timeout - elapsed.elapsed;
      final attemptTimeout = remaining < const Duration(seconds: 2)
          ? remaining
          : const Duration(seconds: 2);
      final client = HttpClient()..connectionTimeout = attemptTimeout;
      try {
        final statusCode = await (() async {
          final req = await client.getUrl(Uri.parse('$baseUrl/health'));
          final resp = await req.close();
          await resp.drain<void>();
          return resp.statusCode;
        })().timeout(attemptTimeout);
        if (statusCode == 200) return _viaJni || _proc != null;
        _log('health check: HTTP $statusCode');
      } catch (_) {
        // Not up yet. Bound the complete exchange, including response-body
        // draining: connectionTimeout alone cannot stop a stalled server.
      } finally {
        client.close(force: true);
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

  /// Stops the backend (JNI or subprocess).
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
    // Deployment and native startup can still be in flight when stop() is
    // called. Wait for that attempt before stopping the resource it owns.
    try {
      await _startFuture;
    } catch (_) {
      // A failed start performs its own cleanup.
    }
    try {
      await _stopRunningBackend();
    } finally {
      await _cancelLogSubscriptions();
      await _logWriteQueue;
    }
  }

  Future<void> _cancelLogSubscriptions() async {
    for (final s in _logSubs) {
      await s.cancel();
    }
    _logSubs.clear();
  }

  Future<void> _stopRunningBackend() async {
    // JNI path
    if (_viaJni) {
      try {
        await _channel.invokeMethod('stopBackend').timeout(_shutdownTimeout);
      } catch (e) {
        _log('stopBackend via JNI failed: $e');
      }
      _viaJni = false;
      return;
    }
    // Subprocess path
    final process = _proc;
    if (process == null) return;
    var exited = false;
    try {
      process.kill();
      try {
        await process.exitCode.timeout(_shutdownTimeout);
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(_shutdownTimeout);
      }
      exited = true;
    } finally {
      if (exited && identical(_proc, process)) _proc = null;
    }
  }
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
