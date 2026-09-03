import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the local Go  backend.
///
/// On Android the backend ships as liblegacy.so (a real c-shared library with
/// JNI exports) and is started via a MethodChannel → Kotlin → JNI path, which
/// avoids the SELinux untrusted_app restriction that blocks Process.start on
/// app_data_file. If the .so is missing or has no exports (old placeholder),
/// or if we are running on desktop, we fall back to spawning the standalone
/// binary via Process.start.
class BackendService {
  BackendService._();

  static final BackendService instance = BackendService._();

  static const int _port = 8080;
  static const String _host = '127.0.0.1';
  static const MethodChannel _channel = MethodChannel('fqapp/backend');

  Process? _proc;
  bool _viaJni = false;
  bool _starting = false;
  final List<StreamSubscription<String>> _logSubs = [];
  final List<String> _logLines = [];
  File? _logFile;

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
    if (!await dest.exists() || await dest.length() != data.lengthInBytes) {
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
  }

  /// Deploys the backend binary + runtime files from assets to disk.
  Future<void> _deploy() async {
    final dir = await _backendDir();

    // Binary
    final bin = File('${dir.path}/');
    await _copyAsset('assets/bin/', bin);
    // Make it executable.
    try {
      await Process.run('chmod', ['755', bin.path]);
    } catch (_) {
      // Windows has no chmod; executable permissions are not needed there.
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
    // Also append to a file for offline diagnosis.
    try {
      _logFile?.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// Starts the backend if not already running.
  ///
  /// On Android we first try the JNI path (liblegacy.so → MethodChannel →
  /// Kotlin → Go c-shared). If that fails — .so missing, no JNI exports, or
  /// running on desktop — we fall back to Process.start with the standalone
  /// binary.
  Future<void> start() async {
    if (_viaJni || _proc != null) return;
    if (_starting) return;
    _starting = true;
    try {
      await _deploy();
      final dir = await _backendDir();

      // Reset log file each start.
      final logPath = '${dir.path}/backend.log';
      try {
        File(logPath).deleteSync();
      } catch (_) {}
      _logFile = File(logPath);

      // --- JNI path (Android only) ---
      if (!kIsWeb && Platform.isAndroid) {
        try {
          _log('trying JNI backend (liblegacy.so)...');
          final result = await _channel.invokeMethod<String>('startBackend', {
            'config': '${dir.path}/config/config.json',
            'pool': '${dir.path}/config/device_pool.json',
            'filter': '${dir.path}/config/filter.json',
          });
          _log('JNI startBackend returned: $result');
          if (result == 'running') {
            _viaJni = true;
            final ok = await _waitHealthy(const Duration(seconds: 15));
            if (!ok) {
              await _channel.invokeMethod('stopBackend');
              _viaJni = false;
              throw StateError(
                'JNI backend started but /health did not come up',
              );
            }
            _log('JNI backend healthy');
            return;
          } else {
            _log('JNI backend failed: $result, falling back to Process.start');
            // A timed-out JNI call may still have a build/listen goroutine in
            // flight. Stop it before starting the subprocess fallback, or the
            // two paths can race for port 8080.
            try {
              await _channel.invokeMethod('stopBackend');
            } catch (stopError) {
              _log('stop timed-out JNI backend failed: $stopError');
            }
          }
        } catch (e) {
          _log('JNI path failed: $e, falling back to Process.start');
        }
      }

      // --- Process.start fallback (desktop / JNI unavailable) ---
      final bin = '${dir.path}/';
      _log('starting backend via Process.start: $bin');
      _log('workdir: ${dir.path}');

      final processEnvironment = Map<String, String>.from(Platform.environment)
        ..['HOME'] = dir.path;
      _proc = await Process.start(
        bin,
        [
          '-config',
          '${dir.path}/config/config.json',
          '-pool',
          '${dir.path}/config/device_pool.json',
          '-filter',
          '${dir.path}/config/filter.json',
          '-runtime-dir',
          dir.path,
        ],
        workingDirectory: dir.path,
        environment: processEnvironment,
      );
      _log('backend pid: ${_proc!.pid}');

      // Drain stdout/stderr so the child never blocks on a full pipe.
      final stdoutLines = _proc!.stdout
          .transform(SystemEncoding().decoder)
          .transform(const LineSplitter());
      _logSubs.add(stdoutLines.listen((String l) => _log(l)));
      final stderrLines = _proc!.stderr
          .transform(SystemEncoding().decoder)
          .transform(const LineSplitter());
      _logSubs.add(stderrLines.listen((String l) => _log(l)));
      _proc!.exitCode.then((code) {
        _log('backend exited with code $code');
        _proc = null;
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
    } finally {
      _starting = false;
    }
  }

  /// Polls /health until the backend responds or [timeout] elapses.
  Future<bool> _waitHealthy(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      // If the process died and we're not on the JNI path, give up.
      if (!_viaJni && _proc == null) return false;
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2);
        try {
          final req = await client.getUrl(Uri.parse('$baseUrl/health'));
          final resp = await req.close();
          await resp.drain<void>();
          if (resp.statusCode == 200) return true;
          _log('health check: HTTP ${resp.statusCode}');
        } finally {
          client.close(force: true);
        }
      } catch (e) {
        // Not up yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  /// Stops the backend (JNI or subprocess).
  Future<void> stop() async {
    // JNI path
    if (_viaJni) {
      try {
        await _channel.invokeMethod('stopBackend');
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
