// Run with the real Linux runner, never flutter test's fake texture boundary.
// See DEVELOPMENT.md for the isolated synthetic-media invocation.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:fqapp/services/app_log.dart';
import 'package:fqapp/services/linux_platform.dart';
import 'package:fqapp/services/native_player.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!predicate()) {
    check(DateTime.now().isBefore(deadline), 'runtime observation timed out');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

// Only listeners owned by this process; excludes the fixture HTTP server.
Set<String> listeners() {
  final sockets = Directory('/proc/self/fd')
      .listSync(followLinks: false)
      .whereType<Link>()
      .map((fd) {
        try {
          return fd.targetSync();
        } catch (_) {
          return '';
        }
      })
      .where((target) => target.startsWith('socket:['))
      .map((target) => target.substring(8, target.length - 1))
      .toSet();
  return File('/proc/self/net/tcp')
      .readAsLinesSync()
      .skip(1)
      .map((line) => line.trim().split(RegExp(r'\s+')))
      .where((fields) => fields[3] == '0A' && sockets.contains(fields[9]))
      .map((fields) => fields[1])
      .toSet();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.instance.install();
  await AppLog.instance.startPersistence(
    directory: Directory('${Platform.environment["HOME"]}/logs'),
  );
  await LinuxPlatform.install();
  runApp(
    const MaterialApp(home: Scaffold(body: Text('Synthetic media runtime'))),
  );
  await WidgetsBinding.instance.endOfFrame;
  try {
    final origin = Platform.environment['FQAPP_RUNTIME_ORIGIN']!;
    final baseline = listeners();
    for (final source in ['audio.wav', 'encrypted.mp4']) {
      final player = NativePlayer(audioOnly: true);
      await player.create(
        '$origin/$source',
        source.endsWith('mp4') ? '00112233445566778899aabbccddeeff' : '',
      );
      stdout.writeln('CREATED $source duration=${player.duration}');
      player.errorStream.listen(
        (error) => stderr.writeln('PLAYER ERROR $error'),
      );
      player.playingStream.listen((value) => stdout.writeln('PLAYING $value'));
      check(player.isCreated, 'created event missing');
      await player.play();
      await until(() => player.playing && player.position.inMilliseconds > 150);
      await player.pause();
      await until(() => !player.playing);
      final paused = player.position;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      check(
        (player.position - paused).inMilliseconds.abs() < 100,
        'paused clock advanced',
      );
      await player.seek(const Duration(seconds: 2));
      await until(() => (player.position.inMilliseconds - 2000).abs() < 250);
      if (source.endsWith('mp4')) {
        check(listeners().difference(baseline).isNotEmpty, 'no CENC listener');
      }
      await player.dispose();
      await until(() => listeners().difference(baseline).isEmpty);
      stdout.writeln(
        'PASS $source created/play/pause/seek/dispose; owned listeners restored',
      );
    }
    final active = NativePlayer(audioOnly: true);
    await active.create(
      '$origin/encrypted.mp4',
      '00112233445566778899aabbccddeeff',
    );
    await active.play();
    await until(() => active.playing && active.position.inMilliseconds > 150);
    check(
      listeners().difference(baseline).isNotEmpty,
      'active session missing',
    );
    LinuxPlatform.beforeClose = () async {
      check(active.playing, 'close must begin during active playback');
      await NativePlayer.pauseOthers();
      stdout.writeln(
        'PASS normal window close entered during active CENC playback',
      );
    };
    stdout.writeln('READY_CLOSE');
    // Uses the real window_manager GTK delete-event and LinuxPlatform listener.
    await windowManager.close();
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exit(1);
  }
}
