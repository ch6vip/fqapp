import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/native_player.dart';
import 'package:fqapp/widgets/player/player_feedback.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'player_playback_rate': 1.25});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  final sourceErrors = [
    (TimeoutException('private-token'), '加载超时'),
    (
      http.ClientException(
        'private-token',
        Uri.parse('https://example.invalid/video'),
      ),
      '网络连接异常',
    ),
    (
      http.ClientException(
        'private-token',
        Uri.parse('http://127.0.0.1:8080/api/content'),
      ),
      '播放服务暂时不可用',
    ),
    (const ApiException('private-token', statusCode: 403), '视频暂时无法播放'),
    (const ApiException('private-token', statusCode: 503), '播放服务暂时不可用'),
    (const ApiException('private-token', statusCode: 504), '加载超时'),
    (StateError('private-token'), '播放失败'),
  ];
  for (var index = 0; index < sourceErrors.length; index++) {
    final (error, title) = sourceErrors[index];
    testWidgets(
      'source failure $index has a useful message and no raw details',
      (tester) async {
        final session = _Session(loader: (_) => Future.error(error));
        await _mount(tester, session);
        expect(find.text(title), findsOneWidget);
        expect(find.textContaining('private-token'), findsNothing);
        expect(find.textContaining(error.runtimeType.toString()), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.widgetWithText(OutlinedButton, '重试'), findsOneWidget);
        await tester.pump(const Duration(seconds: 30));
        expect(session.requests, ['1']);
        expect(session.players, isEmpty);
      },
    );
  }

  for (final scenario in [
    (code: 2001, status: null, title: '网络连接异常'),
    (code: 2002, status: null, title: '加载超时'),
    (code: 2004, status: 403, title: '视频暂时无法播放'),
    (code: 2004, status: 500, title: '播放服务暂时不可用'),
    (code: 4003, status: null, title: '视频解析失败'),
  ]) {
    testWidgets(
      'native ${scenario.code}/${scenario.status} is explained without leaking its message',
      (tester) async {
        final session = _Session();
        await _mount(tester, session);
        session.players.single.emitPosition(const Duration(seconds: 37));
        session.players.single.emitBuffering(true);
        session.players.single.errors.add(
          NativePlaybackException(
            'Source error: https://example.invalid/video?private-token',
            errorCode: scenario.code,
            httpStatusCode: scenario.status,
          ),
        );
        await _flush(tester);
        expect(find.text(scenario.title), findsOneWidget);
        expect(find.textContaining('private-token'), findsNothing);
        expect(find.byType(PlayerLoadingFeedback), findsNothing);
        expect(session.players.single.disposed, true);
        await tester.pump(const Duration(seconds: 10));
        expect(session.requests, ['1']);
        await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
        await tester.pump(const Duration(milliseconds: 350));
        await _flush(tester);
        expect(session.requests, ['1', '1']);
        expect(session.players.last.position, const Duration(seconds: 37));
        expect(session.players.last.rate, 1.25);
        expect(find.byType(PlayerErrorFeedback), findsNothing);
      },
    );
  }

  testWidgets(
    'an empty source has a friendly explanation and stays retryable',
    (tester) async {
      final session = _Session(loader: (_) async => {});
      await _mount(tester, session);
      expect(find.text('视频暂时无法播放'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '重试'), findsOneWidget);
    },
  );

  testWidgets('one wait spans address lookup and the first frame', (
    tester,
  ) async {
    final source = Completer<Map<String, dynamic>>();
    final session = _Session(
      loader: (_) => source.future,
      factory: () => ControlledNativePlayer(hasFirstFrame: false),
    );
    await _mount(tester, session);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('加载较慢'), findsNothing);
    expect(find.text('正在加载第 1 集'), findsOneWidget);
    source.complete(_source('1'));
    await _flush(tester);
    final texture = find.byType(Texture).evaluate().single;
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('加载较慢'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Texture).evaluate().single, same(texture));
    expect(session.requests, ['1']);
    expect(session.players, hasLength(1));
    session.players.single.emitFirstFrame();
    await _flush(tester);
    expect(find.byType(PlayerLoadingFeedback), findsNothing);
    expect(find.byKey(const ValueKey('player-cover')), findsNothing);
    expect(find.byType(Texture).evaluate().single, same(texture));
  });

  testWidgets(
    'separate buffering waits keep the texture and clear their timer',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      final player = session.players.single;
      final texture = find.byType(Texture).evaluate().single;
      final renderObject = texture.renderObject;
      player.emitBuffering(true);
      await _flush(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('缓冲较慢'), findsNothing);
      player.emitBuffering(false);
      await _flush(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(find.byType(PlayerLoadingFeedback), findsNothing);
      player.emitBuffering(true);
      await _flush(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('缓冲较慢'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('缓冲较慢'), findsOneWidget);
      expect(find.byKey(const ValueKey('player-cover')), findsNothing);
      expect(find.byType(Texture).evaluate().single, same(texture));
      expect(texture.renderObject, same(renderObject));
      expect(player.calls.where((call) => call == 'play'), hasLength(1));
      expect(player.calls, isNot(contains('pause')));
      expect(player.disposed, false);
      expect(session.requests, ['1']);
      player.emitBuffering(false);
      await _flush(tester);
      expect(find.byType(PlayerLoadingFeedback), findsNothing);
    },
  );

  testWidgets(
    'buffering retry refreshes once and restores the current progress',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      final player = session.players.single;
      player.emitPosition(const Duration(seconds: 42));
      player.emitBuffering(true);
      await _flush(tester);
      await tester.pump(const Duration(seconds: 9));
      final retry = tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '重试'))
          .onPressed!;
      await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
      await tester.pump(const Duration(milliseconds: 350));
      retry(); // A callback from the retired overlay must not start another load.
      await _flush(tester);
      expect(session.requests, ['1', '1']);
      expect(session.players, hasLength(2));
      expect(player.calls.where((call) => call == 'dispose'), hasLength(1));
      expect(session.players.last.position, const Duration(seconds: 42));
      expect(session.players.last.rate, 1.25);
      expect(find.byType(PlayerLoadingFeedback), findsNothing);
    },
  );

  testWidgets('retrying a slow lookup ignores its late error', (tester) async {
    final original = Completer<Map<String, dynamic>>();
    var attempts = 0;
    final session = _Session(
      loader: (_) =>
          attempts++ == 0 ? original.future : Future.value(_source('fresh')),
    );
    await _mount(tester, session);
    await tester.pump(const Duration(seconds: 9));
    await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
    await tester.pump(const Duration(milliseconds: 350));
    await _flush(tester);
    expect(session.requests, ['1', '1']);
    expect(session.players.single.calls.first, contains('/fresh.mp4'));
    original.completeError(TimeoutException('obsolete request'));
    await _flush(tester);
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(PlayerErrorFeedback), findsNothing);
    expect(find.byType(PlayerLoadingFeedback), findsNothing);
    expect(session.players.single.isPlaying, true);
    expect(session.requests, ['1', '1']);
  });

  testWidgets(
    'switching episodes starts a fresh wait and retires old actions',
    (tester) async {
      final original = Completer<Map<String, dynamic>>();
      final session = _Session(
        episodeCount: 2,
        loader: (chapter) => chapter.itemId == '1'
            ? original.future
            : Future.value(_source('2')),
        factory: () => ControlledNativePlayer(hasFirstFrame: false),
      );
      await _mount(tester, session);
      await tester.pump(const Duration(seconds: 9));
      final oldRetry = tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '重试'))
          .onPressed!;
      unawaited(_chrome(tester).onSelectEpisode(1));
      await _flush(tester);
      oldRetry();
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('加载较慢'), findsNothing);
      expect(find.text('正在加载第 2 集'), findsOneWidget);
      expect(session.requests, ['1', '2']);
      original.complete(_source('1'));
      await _flush(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('加载较慢'), findsOneWidget);
      expect(session.players, hasLength(1));
      expect(_chrome(tester).currentIndex, 1);
      session.players.single.emitFirstFrame();
      await _flush(tester);
      expect(find.byType(PlayerLoadingFeedback), findsNothing);
    },
  );

  testWidgets(
    'background time and a disposed page cannot trigger slow feedback',
    (tester) async {
      final source = Completer<Map<String, dynamic>>();
      final session = _Session(loader: (_) => source.future);
      await _mount(tester, session);
      await tester.pump(const Duration(seconds: 6));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('加载较慢'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('加载较慢'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('加载较慢'), findsOneWidget);
      expect(session.requests, ['1']);
      await tester.pumpWidget(const SizedBox.shrink());
      source.complete(_source('1'));
      await _flush(tester);
      await tester.pump(const Duration(seconds: 30));
      expect(session.players, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'feedback remains readable and retryable in a small large-text area',
    (tester) async {
      var retries = 0;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: SizedBox(
                  width: 200,
                  height: 120,
                  child: PlayerLoadingFeedback(onRetry: () => retries++),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 9));
      expect(tester.takeException(), isNull);
      final retry = find.widgetWithText(OutlinedButton, '重试');
      await tester.ensureVisible(retry);
      await tester.pump();
      await tester.tap(retry);
      expect(retries, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [const Size(80, 40), const Size(40, 24)]) {
    testWidgets('expanded-panel video strip $size keeps retry reachable', (
      tester,
    ) async {
      var retries = 0;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox.fromSize(
                size: size,
                child: PlayerLoadingFeedback(onRetry: () => retries++),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 9));
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
      expect(retries, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'no episodes gives an explanation without retry or a waiting timer',
    (tester) async {
      final session = _Session(episodeCount: 0);
      await _mount(tester, session);
      expect(find.text('暂无可播放剧集'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('重试'), findsNothing);
      expect(find.byType(PlayerLoadingFeedback), findsNothing);
      expect(session.requests, isEmpty);
    },
  );
}

Map<String, dynamic> _source(String id) => {
  'video_url': 'https://example.invalid/$id.mp4',
};

VideoPlayerChrome _chrome(WidgetTester tester) =>
    tester.widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome));

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _mount(WidgetTester tester, _Session session) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

class _Session {
  final store = ControlledReaderStore();
  final Future<Map<String, dynamic>> Function(Chapter)? loader;
  final ControlledNativePlayer Function()? factory;
  final int episodeCount;
  final players = <ControlledNativePlayer>[];
  final requests = <String>[];

  _Session({this.loader, this.factory, this.episodeCount = 1});

  Widget app() => MaterialApp(
    home: PlayerPage(
      bookId: 'feedback-book',
      title: '播放提示测试',
      description: '测试简介',
      eps: [
        for (var index = 1; index <= episodeCount; index++)
          Chapter(itemId: '$index', title: '第 $index 集', volumeName: ''),
      ],
      startIndex: 0,
      historyStore: store,
      contentLoader: (chapter) {
        requests.add(chapter.itemId);
        return loader?.call(chapter) ?? Future.value(_source(chapter.itemId));
      },
      playerFactory: () {
        final player = factory?.call() ?? ControlledNativePlayer();
        players.add(player);
        return player;
      },
    ),
  );
}
