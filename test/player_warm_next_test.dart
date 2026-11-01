import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';

/// 切集的两道保险：快播完时预热下一集并在切集时直接接管；
/// 还没出画面的集失败后先静默重来（新地址 → 换一档清晰度）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  group('warm next episode', () {
    testWidgets('is built near the end and taken over on completion', (
      tester,
    ) async {
      final session = _Session(episodeCount: 3);
      await _mount(tester, session);
      final first = session.players.single;
      first.emitDuration(const Duration(minutes: 2));
      first.emitPosition(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      expect(session.players, hasLength(1), reason: 'too early to warm up');

      first.emitPosition(const Duration(seconds: 95));
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      expect(session.players, hasLength(2));
      final warm = session.players[1];
      expect(warm.calls, contains('create:https://example.invalid/2.mp4'));
      expect(warm.calls, isNot(contains('play')));
      expect(session.requests, ['1', '2']);

      first.emitCompleted();
      await _flush(tester);
      await _flush(tester);
      expect(session.players, hasLength(2), reason: 'no third player');
      expect(session.requests, ['1', '2'], reason: 'no second address fetch');
      expect(first.disposed, isTrue);
      expect(warm.disposed, isFalse);
      expect(warm.calls, contains('play'));
      expect(find.text('播放失败'), findsNothing);
    });

    testWidgets('a warm player that fails is dropped and the switch reloads', (
      tester,
    ) async {
      final session = _Session(episodeCount: 3);
      await _mount(tester, session);
      final first = session.players.single;
      first.emitDuration(const Duration(minutes: 2));
      first.emitPosition(const Duration(seconds: 100));
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      final warm = session.players[1];
      warm.errors.add(StateError('stalled'));
      await _flush(tester);
      expect(warm.disposed, isTrue);

      first.emitCompleted();
      await _flush(tester);
      await _flush(tester);
      final third = session.players.last;
      expect(session.players, hasLength(3));
      expect(third.calls, contains('play'));
      // 预热用过的地址作废了，切过去重新取。
      expect(session.requests, ['1', '2', '2']);
    });

    testWidgets('a quality switch drops the warm player', (tester) async {
      final session = _Session(episodeCount: 3, variants: true);
      await _mount(tester, session);
      final first = session.players.single;
      first.emitDuration(const Duration(minutes: 2));
      first.emitPosition(const Duration(seconds: 100));
      await tester.pump(const Duration(seconds: 5));
      await _flush(tester);
      final warm = session.players[1];
      expect(warm.disposed, isFalse);

      final chrome = tester.widget<VideoPlayerChrome>(
        find.byType(VideoPlayerChrome),
      );
      chrome.onQualitySelected!(chrome.qualityVariants.last);
      await _flush(tester);
      expect(warm.disposed, isTrue);
    });
  });

  group('silent retry', () {
    testWidgets('an address failure retries before showing an error', (
      tester,
    ) async {
      var failures = 1;
      final session = _Session(
        loader: (chapter) => failures-- > 0
            ? Future.error(StateError('upstream hiccup'))
            : Future.value(_source(chapter.itemId)),
      );
      await _mount(tester, session);
      await _flush(tester);
      expect(find.text('播放失败'), findsNothing);
      expect(session.requests, ['1', '1']);
      expect(session.players.single.calls, contains('play'));
    });

    testWidgets('the second retry falls back to another quality tier', (
      tester,
    ) async {
      var created = 0;
      final session = _Session(
        variants: true,
        factory: () => created++ < 2 ? _FailingCreate() : null,
      );
      await _mount(tester, session);
      await _flush(tester);
      await _flush(tester);
      expect(find.text('播放失败'), findsNothing);
      expect(session.requests, ['1', '1', '1']);
      expect(session.players, hasLength(3));
      expect(
        session.players[0].calls.first,
        'create:https://example.invalid/1-1080.mp4',
      );
      expect(
        session.players[1].calls.first,
        'create:https://example.invalid/1-1080.mp4',
      );
      expect(
        session.players[2].calls.first,
        'create:https://example.invalid/1-720.mp4',
      );
      expect(session.players[2].calls, contains('play'));
    });

    testWidgets('gives up after two silent retries', (tester) async {
      final session = _Session(factory: _FailingCreate.new);
      await _mount(tester, session);
      await _flush(tester);
      await _flush(tester);
      expect(find.text('播放失败'), findsOneWidget);
      expect(session.players, hasLength(3));
    });
  });

  group('fallbackVariant', () {
    EpisodeVariant variant(String name, String url) =>
        EpisodeVariant(name: name, url: url, keyHex: '', height: 0);

    test('prefers the next lower tier with a different stream', () {
      final tiers = [
        variant('1080p', 'a'),
        variant('720p', 'a'),
        variant('480p', 'b'),
      ];
      expect(fallbackVariant(tiers, '1080p')?.name, '480p');
      expect(fallbackVariant(tiers, '480p')?.name, '720p');
      expect(fallbackVariant(tiers, 'unknown'), isNull);
      expect(fallbackVariant([variant('only', 'a')], 'only'), isNull);
    });
  });
}

class _FailingCreate extends ControlledNativePlayer {
  @override
  Future<int> create(String cdnUrl, String keyHex, {int? startMs}) async {
    calls.add('create:$cdnUrl');
    throw StateError('media open failed');
  }
}

Map<String, dynamic> _source(String id, {bool variants = false}) => {
  'video_url': variants
      ? 'https://example.invalid/$id-1080.mp4'
      : 'https://example.invalid/$id.mp4',
  if (variants)
    'variants': [
      {
        'name': '1080p',
        'url': 'https://example.invalid/$id-1080.mp4',
        'height': 1080,
      },
      {
        'name': '720p',
        'url': 'https://example.invalid/$id-720.mp4',
        'height': 720,
      },
    ],
};

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
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

var _sessions = 0;

class _Session {
  // 画质记忆按剧共享（[QualityMemory]）：每个用例一部新剧，互不串档。
  final bookId = 'warm-book-${_sessions++}';
  final store = ControlledReaderStore();
  final Future<Map<String, dynamic>> Function(Chapter)? loader;
  final ControlledNativePlayer? Function()? factory;
  final int episodeCount;
  final bool variants;
  final players = <ControlledNativePlayer>[];
  final requests = <String>[];

  _Session({
    this.loader,
    this.factory,
    this.episodeCount = 1,
    this.variants = false,
  });

  Widget app() => MaterialApp(
    home: PlayerPage(
      bookId: bookId,
      title: '预热测试',
      eps: [
        for (var index = 1; index <= episodeCount; index++)
          Chapter(itemId: '$index', title: '第 $index 集', volumeName: ''),
      ],
      startIndex: 0,
      shortSeries: true,
      danmakuFetcher: (_) async => const PlayletCommentPage(),
      historyStore: store,
      contentLoader: (chapter) {
        requests.add(chapter.itemId);
        return loader?.call(chapter) ??
            Future.value(_source(chapter.itemId, variants: variants));
      },
      playerFactory: () {
        final player = factory?.call() ?? ControlledNativePlayer();
        players.add(player);
        return player;
      },
    ),
  );
}
