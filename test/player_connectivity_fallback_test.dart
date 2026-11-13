import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/drama_cache_preferences.dart';
import 'package:fqapp/services/drama_download_store.dart';
import 'package:fqapp/services/quality_memory.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

const _connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
const _native = MethodChannel('fqapp/native_player');
final _requests = <String>[];

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Keep contentLoader null so playback uses the production source resolver.
    http.runWithClient(
      () => ApiClient.instance,
      () => MockClient((request) async {
        if (request.url.path.contains('/videos/')) {
          final id = request.url.pathSegments.last;
          _requests.add(id);
          return http.Response(
            jsonEncode({'video_url': 'https://example.invalid/$id.mp4'}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response('{}', 200);
      }),
    );
  });

  for (final rate in [1.0, 1.25]) {
    testWidgets(
      'cached episodes advance to an online source despite OS offline at ${rate}x',
      (tester) async {
        SharedPreferences.setMockInitialValues({'player_playback_rate': rate});
        DramaCachePreferences.instance.resetForTest();
        QualityMemory.clearForTesting();
        _requests.clear();
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          _connectivity,
          (_) async => ['none'],
        );
        messenger.setMockMethodCallHandler(_native, (_) async => null);
        final root = Directory.systemTemp.createTempSync('player-offline-');
        final store = MemoryDramaDownloadStore(videoDirectory: root);
        final players = <ControlledNativePlayer>[];
        final episodes = [
          for (var n = 1; n <= 20; n++)
            Chapter(itemId: 'episode-$n', title: '第 $n 集', volumeName: ''),
        ];
        await tester.binding.setSurfaceSize(const Size(400, 800));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          for (var i = 0; i < 5; i++) {
            await _flush(tester);
          }
          messenger.setMockMethodCallHandler(_connectivity, null);
          messenger.setMockMethodCallHandler(_native, null);
          DramaCachePreferences.instance.resetForTest();
          QualityMemory.clearForTesting();
          await tester.binding.setSurfaceSize(null);
          root.deleteSync(recursive: true);
        });
        for (var n = 11; n < 20; n++) {
          final file = File('${root.path}/episode-$n.mp4')
            ..writeAsBytesSync([n]);
          await store.saveEpisode(
            CachedEpisode(
              seriesId: 'series',
              itemId: 'episode-$n',
              title: '第 $n 集',
              index: n - 1,
              keyHex: '',
              height: 96,
              variantName: 'fixture',
              bytes: 1,
              filePath: file.path,
              cachedAt: 0,
              auto: true,
            ),
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              bookId: 'series',
              title: '连续播放测试',
              eps: episodes,
              startIndex: 10,
              historyStore: MemoryReaderStore(),
              store: store,
              playerFactory: () {
                final player = ControlledNativePlayer(hasFirstFrame: true);
                players.add(player);
                return player;
              },
            ),
          ),
        );
        for (var n = 11; n <= 20; n++) {
          for (var retry = 0; retry < 80; retry++) {
            await _flush(tester);
            if (players.isNotEmpty &&
                players.last.isPlaying &&
                players.last.calls.any(
                  (call) => call.contains('episode-$n.mp4'),
                )) {
              break;
            }
          }
          expect(players, isNotEmpty);
          expect(players.last.isPlaying, isTrue, reason: 'episode $n');
          expect(
            players.last.calls.any((call) => call.contains('episode-$n.mp4')),
            isTrue,
            reason: 'episode $n must use its own source',
          );
          expect(players.last.rate, rate, reason: 'episode $n');
          if (n < 20) {
            players.last.emitCompleted();
            await _flush(tester);
          }
        }
        expect(_requests, ['episode-20']);
      },
    );
  }
}
