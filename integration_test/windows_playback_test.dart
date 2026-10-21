import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/services/app_log.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/widgets/desktop_app_frame.dart';

import '../test/support/fakes.dart' show MemoryReaderStore;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows production player autoplays and resumes after a seek', (
    tester,
  ) async {
    if (!Platform.isWindows) return;
    const path = String.fromEnvironment('FQAPP_TEST_MEDIA');
    expect(
      path,
      isNotEmpty,
      reason: 'Pass an encrypted fixture with --dart-define',
    );
    expect(File(path).existsSync(), isTrue);
    final fixture = await File(path).readAsBytes();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final range = request.headers.value('range');
      final match = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      final start = match == null ? 0 : int.parse(match[1]!);
      final end = match == null || match[2]!.isEmpty
          ? fixture.length - 1
          : int.parse(match[2]!).clamp(0, fixture.length - 1);
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.headers.set('accept-ranges', 'bytes');
      if (match != null) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/${fixture.length}',
        );
      }
      request.response.contentLength = end - start + 1;
      if (request.method != 'HEAD') {
        request.response.add(fixture.sublist(start, end + 1));
      }
      await request.response.close();
    });
    SharedPreferences.setMockInitialValues({});
    AppLog.instance.install();
    await DesktopPlatform.instance.initialize();
    final player = NativePlayer();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: DesktopPlatform.navigatorKey,
        builder: (context, child) => AudioPlaybackScope(
          navigatorKey: DesktopPlatform.navigatorKey,
          child: DesktopAppFrame(child: child!),
        ),
        home: PlayerPage(
          bookId: 'desktop-native-test',
          title: 'Windows 原生播放回归',
          eps: [Chapter(itemId: 'fixture', title: '第 1 集', volumeName: '')],
          startIndex: 0,
          historyStore: MemoryReaderStore(),
          playerFactory: () => player,
          contentLoader: (_) async => {
            'video_url': 'http://127.0.0.1:${server.port}/fixture.mp4',
            'key_hex': '00112233445566778899aabbccddeeff',
          },
        ),
      ),
    );

    Future<void> waitFor(bool Function() condition, String description) async {
      final until = DateTime.now().add(const Duration(seconds: 20));
      while (!condition()) {
        if (DateTime.now().isAfter(until)) {
          fail(
            '$description: lifecycle=${tester.binding.lifecycleState}, '
            'playing=${player.playing}, requested=${player.playWhenReady}, '
            'position=${player.position}, error=${player.lastError}',
          );
        }
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    await waitFor(() => player.position.inMilliseconds > 1500, 'autoplay');
    expect(player.playing, isTrue);
    await tester.tap(find.byTooltip('播放 / 暂停（空格）'));
    await tester.pump();
    await waitFor(() => !player.playing, 'pause');

    Future<void> scrub(double fraction) async {
      final slider = find.byType(Slider).first;
      final box = tester.getRect(slider);
      await tester.tapAt(
        Offset(box.left + box.width * fraction, box.center.dy),
      );
      await tester.pump();
    }

    await scrub(.4);
    await waitFor(() => player.position.inMilliseconds > 2500, 'paused seek');
    expect(player.playing, isFalse);
    await tester.tap(find.byTooltip('播放 / 暂停（空格）'));
    await tester.pump();
    await waitFor(() => player.position.inMilliseconds > 4500, 'seek/resume');
    expect(player.playing, isTrue);
    await scrub(.25);
    await waitFor(() => player.position.inMilliseconds < 3000, 'playing seek');
    await waitFor(
      () => player.position.inMilliseconds > 3500,
      'continuous playback after seek',
    );
    expect(player.playing, isTrue);
    final report = File('build/validation/windows-widget-player.json');
    await report.parent.create(recursive: true);
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'passed': true,
        'engine':
            'production Windows adapter, media_kit Video, Rust/C loopback',
        'checks': [
          'autoplay while Windows window is visible without input focus',
          'position advances continuously',
          'pause through production controls',
          'slider seek preserves pause intent',
          'resume through production controls',
          'slider seek while playing continues playback',
        ],
        'positionMs': player.position.inMilliseconds,
        'lifecycle': tester.binding.lifecycleState.toString(),
        'note':
            'Generated encrypted fixture in the actual Windows runner; upstream content acceptance is a separate user test.',
      }),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await player.dispose();
  });
}
