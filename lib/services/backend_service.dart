import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the local Go  backend.
///
/// On Android the backend ships as liblegacy.so (a real c-shared library with
/// JNI exports) and is started via a MethodChannel → Kotlin → JNI path. The
/// standalone executable is deployed only on desktop; Android cannot execute
/// app-data binaries under SELinux and therefore uses the JNI backend only.
class BackendService {
  BackendService._();

  static final BackendService instance = BackendService._();

  static const int _port = 8080;
  static const String _host = '127.0.0.1';
  static const MethodChannel _channel = MethodChannel('fqapp/backend');

  Process? _proc;
  bool _viaJni = false;
  Future<void>? _startFuture;
  final List<StreamSubscription<String>> _logSubs = [];
  final List<String> _logLines = [];
  File? _logFile;
  // Serializes async log-file writes so concurrent appends don't interleave.
  Future<void> _logWriteQueue = Future.value();

  /// Base URL of the local backend.
  String get baseUrl => 'http://$_host:$_port';

  /// Whether the backend is currently running (via JNI or as a subprocess).
  bool get isRunning => _viaJni || (_proc != null && _proc!.pid > 0);

  /// Recent backend log lines (for diagnostics).
  List<String> get logLines => List.unmodifiable(_logLines);

  /// Path of the directory where backend files live.
  Future<Directory> _backendDir() async {
    final dir = await getApplicationSupportDirectory();
    final backend = Directory('${dir.path}/backend');
    if (!await backend.exists()) {
      await backend.create(recursive: true);
    }
    return backend;
  }

  /// Copies an asset bundle entry to [dest] if missing or stale.
  Future<void> _copyAsset(String assetPath, File dest) async {
    final data = await rootBundle.load(assetPath);
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

    // Filters
    final filterNames = [
      'article.js',
      'audio.js',
      'author.js',
      'book.js',
      'chapter.js',
      'comment.js',
      'forum_id.js',
      'item.js',
      'manga.js',
      'novel.js',
      'rank.js',
      'recommend.js',
      'search.js',
      'video.js',
      'viewer.js',
    ];
    for (final n in filterNames) {
      await _copyAsset('assets/filters/$n', File('${dir.path}/filters/$n'));
    }

    // Web UI (used by browser; Flutter uses the API directly but keep parity)
    final webNames = [
      'index.html',
      'detail.html',
      'read.html',
      'listen.html',
      'comic.html',
      'video.html',
    ];
    for (final n in webNames) {
      await _copyAsset('assets/web/$n', File('${dir.path}/web/$n'));
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
    if (_viaJni || _proc != null) return Future<void>.value();
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
      final android = !kIsWeb && Platform.isAndroid;
      await _deploy(includeExecutable: !android);
      final dir = await _backendDir();

      // Reset log file each start.
      final logPath = '${dir.path}/backend.log';
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
            final ok = await _waitHealthy(const Duration(seconds: 15));
            if (!ok) {
              await _channel
                  .invokeMethod('stopBackend')
                  .timeout(const Duration(seconds: 3));
              _viaJni = false;
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
                .timeout(const Duration(seconds: 3));
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

      _proc = await Process.start(bin, [
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
          .transform(SystemEncoding().decoder)
          .transform(const LineSplitter());
      _logSubs.add(stdoutLines.listen((String l) => _log(l)));
      final stderrLines = process.stderr
          .transform(SystemEncoding().decoder)
          .transform(const LineSplitter());
      _logSubs.add(stderrLines.listen((String l) => _log(l)));
      process.exitCode.then((code) {
        _log('backend exited with code $code');
        if (identical(_proc, process)) _proc = null;
      });

      // Wait for the health endpoint to come up.
      final ok = await _waitHealthy(const Duration(seconds: 15));
      if (!ok) {
        // Kill and report failure.
        _proc?.kill();
        _proc = null;
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
    final deadline = DateTime.now().add(timeout);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      while (DateTime.now().isBefore(deadline)) {
        // If the process died and we're not on the JNI path, give up.
        if (!_viaJni && _proc == null) return false;
        try {
          final req = await client.getUrl(Uri.parse('$baseUrl/health'));
          final resp = await req.close();
          await resp.drain<void>();
          if (resp.statusCode == 200) return true;
          _log('health check: HTTP ${resp.statusCode}');
        } catch (e) {
          // Not up yet.
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Stops the backend (JNI or subprocess).
  Future<void> stop() async {
    // JNI path
    if (_viaJni) {
      try {
        await _channel
            .invokeMethod('stopBackend')
            .timeout(const Duration(seconds: 3));
      } catch (e) {
        _log('stopBackend via JNI failed: $e');
      }
      _viaJni = false;
      return;
    }
    // Subprocess path
    if (_proc == null) return;
    try {
      _proc?.kill();
      await _proc?.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => -1,
      );
    } finally {
      _proc = null;
      for (final s in _logSubs) {
        await s.cancel();
      }
      _logSubs.clear();
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
