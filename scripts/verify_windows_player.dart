import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:media_kit/media_kit.dart';
import 'package:fqapp/services/desktop_media.dart';

Future<void> until(FutureOr<bool> Function() condition, String stage) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!(await condition())) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Player verification timed out: $stage');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> servePlainAudio((String, SendPort) arguments) async {
  final file = File(arguments.$1);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final stop = ReceivePort();
  arguments.$2.send((server.port, stop.sendPort));
  server.listen((request) async {
    try {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = await file.length();
      if (request.method != 'HEAD') {
        await request.response.addStream(file.openRead());
      }
      await request.response.close();
    } catch (_) {
      await request.response.close();
    }
  });
  await stop.first;
  await server.close(force: true);
  stop.close();
}

Future<void> main() async {
  final root = Directory.current;
  final output = Directory('${root.path}/build/validation/windows-player');
  await output.create(recursive: true);
  final reportFile = File('${output.path}/report.json');
  if (await reportFile.exists()) await reportFile.delete();
  final reference = File('${output.path}/reference.mp4');
  final encrypted = File('${output.path}/encrypted.mp4');
  Future<void> ffmpeg(List<String> args) async {
    final result = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-y',
      ...args,
    ]);
    if (result.exitCode != 0) {
      throw StateError('FFmpeg fixture generation failed');
    }
  }

  await ffmpeg([
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=160x96:rate=12',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=880:sample_rate=44100',
    '-t',
    '8',
    '-c:v',
    'libx264',
    '-preset',
    'ultrafast',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'aac',
    reference.path,
  ]);
  const key = '00112233445566778899aabbccddeeff';
  await ffmpeg([
    '-i',
    reference.path,
    '-map',
    '0',
    '-c',
    'copy',
    '-encryption_scheme',
    'cenc-aes-ctr',
    '-encryption_key',
    key,
    '-encryption_kid',
    '102132435465768798a9bacbdcedfe0f',
    encrypted.path,
  ]);
  MediaKit.ensureInitialized(
    libmpv: File(
      '${root.path}/build/windows/x64/runner/Release/libmpv-2.dll',
    ).path,
  );
  final player = Player(
    configuration: const PlayerConfiguration(
      vo: 'null',
      title: 'fqapp media verification',
    ),
  );
  final media = await DesktopMedia.open(encrypted.uri.toString(), key);
  final errors = <String>[];
  final subscription = player.stream.error.listen(errors.add);
  late Map<String, Object?> report;
  try {
    // Hosted Windows runners may have no WASAPI endpoint. Keep real decoding
    // and playback timing, without requiring a physical audio device.
    await (player.platform as NativePlayer).setProperty('ao', 'null');
    await player.setVolume(0);
    await player.open(Media(media.url), play: false);
    await until(() => player.state.duration.inSeconds >= 7, 'duration');
    await player.setVideoTrack(VideoTrack.auto());
    await player.setRate(1.5);
    await player.play();
    await until(() => player.state.position.inMilliseconds > 500, 'play');
    await until(
      () => player.state.width == 160 && player.state.height == 96,
      'video decode dimensions',
    );
    await player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final paused = player.state.position;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if ((player.state.position - paused).inMilliseconds.abs() > 100) {
      throw StateError('Pause did not hold');
    }
    await player.seek(const Duration(seconds: 4));
    await until(() => player.state.position.inMilliseconds >= 3500, 'seek');
    await player.play();
    await until(() => player.state.position.inMilliseconds >= 5000, 'resume');
    if (player.state.rate != 1.5 ||
        player.state.volume != 0 ||
        errors.isNotEmpty) {
      throw StateError('Engine playback settings/error verification failed');
    }
    final decodedWidth = player.state.width;
    final decodedHeight = player.state.height;
    final decodedDuration = player.state.duration;
    // Plain MP3 originates from a separate isolate and deliberately ignores Range.
    await player.stop();
    final plainAudio = File('${output.path}/plain.mp3');
    await ffmpeg([
      '-i',
      reference.path,
      '-map',
      '0:a:0',
      '-c:a',
      'libmp3lame',
      '-b:a',
      '64k',
      plainAudio.path,
    ]);
    final started = ReceivePort();
    await Isolate.spawn(servePlainAudio, (plainAudio.path, started.sendPort));
    final origin = await started.first as (int, SendPort);
    started.close();
    try {
      await player.open(
        Media('http://127.0.0.1:${origin.$1}/plain.mp3'),
        play: false,
      );
      await player.play();
      await until(
        () => player.state.position.inMilliseconds > 500,
        'plain HTTP 200 audio playback',
      );
    } finally {
      // Unload the HTTP input before tearing down the isolate that serves it.
      await player.stop();
      await until(
        () async =>
            await (player.platform as NativePlayer).getProperty(
              'idle-active',
            ) ==
            'yes',
        'idle before origin shutdown',
      );
      origin.$2.send(null);
    }
    report = {
      'passed': true,
      'engine': 'bundled libmpv via media_kit',
      'checks': [
        'encrypted media through Rust/C loopback',
        'duration',
        'H264 video decode dimensions',
        'plain MP3 HTTP 200 origin',
        'play',
        'pause',
        'seek',
        'resume',
        '1.5x rate',
        'mute',
        'idle before origin shutdown',
        'delayed native player destruction',
      ],
      'durationMs': decodedDuration.inMilliseconds,
      'width': decodedWidth,
      'height': decodedHeight,
      'note':
          'Native engine test with null audio/video outputs; physical audio and GPU/window rendering are separate acceptance checks.',
    };
  } catch (_) {
    stderr.writeln(
      jsonEncode({
        'playing': player.state.playing,
        'positionMs': player.state.position.inMilliseconds,
        'durationMs': player.state.duration.inMilliseconds,
        'fixtureErrors': errors,
      }),
    );
    rethrow;
  } finally {
    await subscription.cancel();
    await player.dispose();
    media.close();
    // media_kit 1.2.6 schedules mpv_terminate_destroy five seconds after dispose.
    // A passing report must also mean that delayed teardown survived.
    await Future<void>.delayed(const Duration(seconds: 6));
  }
  await File(
    '${output.path}/report.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(jsonEncode(report));
}
