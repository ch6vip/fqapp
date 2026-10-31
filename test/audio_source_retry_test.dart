import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/audio_time_track.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/listening_session.dart';

import 'support/controlled_player.dart';

/// 音源路由收到的每一次请求。
final _sourceRequests = <Uri>[];

/// 本次测试的音源应答；其他路由由 [_handle] 兜底。
Future<http.Response> Function(http.Request request) _sourceResponse =
    (_) async => http.Response('{}', 404);

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<http.Response> _handle(http.Request request) {
  final path = request.url.path;
  if (path.contains('/audio/books/') && path.contains('/chapters/')) {
    _sourceRequests.add(request.url);
    return _sourceResponse(request);
  }
  return Future.value(_json({'code': 0, 'data': <String, Object>{}}, 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // 听书页默认走 ApiClient.instance；在 mock 客户端所在的 Zone 里先把它
    // 建出来，之后所有请求都经过 _handle。
    http.runWithClient(() => ApiClient.instance, () => MockClient(_handle));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
    _sourceRequests.clear();
    _sourceResponse = (_) async => http.Response('{}', 404);
  });

  testWidgets('a 404 audio source fails after one request, not three', (
    tester,
  ) async {
    _sourceResponse = (_) async => _json({'error': '章节不存在'}, 404);

    await _mount(tester);
    await _pumpUntil(tester, () => tester.any(find.text('播放出错，请稍后重试')));

    expect(find.text('播放出错，请稍后重试'), findsOneWidget);
    expect(_sourceRequests, hasLength(1), reason: '404 再试也是同一个结果');
  });

  testWidgets('the NO_THIS_TONE fallback uses the same fail-fast policy', (
    tester,
  ) async {
    _sourceResponse = (request) async {
      // tone 0 是这本纯 TTS 书没有的默认音色；换用音色 1 时给 404。
      final tone = request.url.queryParameters['tone_id'];
      if (tone == '0') {
        return _json({'code': 101000, 'message': 'NO_THIS_TONE'}, 200);
      }
      return _json({'error': '章节不存在'}, 404);
    };

    await _mount(tester);
    await _pumpUntil(tester, () => tester.any(find.text('播放出错，请稍后重试')));

    expect(
      _sourceRequests.map((url) => url.queryParameters['tone_id']),
      ['0', '1'],
      reason: '回退音色的 404 也只请求一次',
    );
  });

  testWidgets('a 5xx audio source is retried and then plays', (tester) async {
    var attempts = 0;
    _sourceResponse = (_) async {
      attempts++;
      if (attempts == 1) {
        return _json({'error': '服务暂不可用'}, 503);
      }
      return _json(_playinfoPayload(), 200);
    };

    final players = <ControlledNativePlayer>[];
    await _mount(tester, players: players);
    await _pumpUntil(
      tester,
      () => players.isNotEmpty && players.single.isPlaying,
      settleMs: 700,
    );

    expect(_sourceRequests, hasLength(2), reason: '5xx 值得再取一次');
    expect(players, isNotEmpty);
    expect(players.single.isPlaying, isTrue);
  });
}

Map<String, dynamic> _playinfoPayload() => {
  'code': 0,
  'data': [
    {
      'main_url': 'https://cdn.example/1.m4a',
      'item_id': '1',
      'indate': 86400,
      'video_model': jsonEncode({
        'status': 10,
        'media_type': 'audio',
        'video_duration': 42.0,
        'video_list': [
          {'main_url': 'https://cdn.example/1.m4a'},
        ],
      }),
    },
  ],
};

Widget _app(List<ControlledNativePlayer> players) => MaterialApp(
  home: AudioPage(
    bookId: 'book',
    title: '测试听书',
    chapters: [Chapter(itemId: '1', title: '第1章', volumeName: '')],
    historyStore: ControlledReaderStore(),
    voicesLoader: () async => const [AudioVoice(id: '1', label: '音色一')],
    extrasLoader: (_) async => const AudioExtras(),
    subtitleLoader: (_, _) async => SubtitleTrack.empty,
    timePointLoader: (_, _) async => AudioTimeTrack.empty,
    excerptLoader: (_) async => null,
    directoryLoader: (_) async => const [],
    playerFactory: () {
      final player = ControlledNativePlayer();
      players.add(player);
      return player;
    },
  ),
);

Future<void> _mount(
  WidgetTester tester, {
  List<ControlledNativePlayer>? players,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(_app(players ?? []));
  await _flush(tester);
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

/// 等真实 isolate / 网络回调与重试退避都跑完，直到 [done] 成立。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int settleMs = 16,
}) async {
  for (var i = 0; i < 80 && !done(); i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(Duration(milliseconds: settleMs));
  }
  expect(done(), isTrue);
}
