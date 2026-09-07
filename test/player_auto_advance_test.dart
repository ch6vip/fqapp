import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/services/player_preferences.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (_) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  testWidgets('automatic next episode remains enabled by default', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    expect(_chrome(tester).autoAdvance, isTrue);
    final first = session.players.single;
    first.emitCompleted();
    first.emitCompleted();
    await _flush(tester);
    expect(_chrome(tester).currentIndex, 1);
    expect(session.players, hasLength(2));
    expect(
      session.players.last.calls.where((call) => call == 'play'),
      hasLength(1),
    );
    await _unmount(tester);
  });

  testWidgets(
    'saved stop-at-end keeps the episode and position but permits manual next',
    (tester) async {
      SharedPreferences.setMockInitialValues({'player_auto_advance': false});
      final session = _Session();
      await _mount(tester, session);
      final first = session.players.single;
      await first.pause();
      first.emitCompleted();
      await _flush(tester);
      expect(_chrome(tester).autoAdvance, isFalse);
      expect(_chrome(tester).currentIndex, 0);
      expect(session.players, hasLength(1));
      expect(session.store.entry?['position'], 120);
      expect(find.byTooltip('播放'), findsOneWidget);
      await tester.tap(find.byTooltip('下一集'));
      await _flush(tester);
      expect(_chrome(tester).currentIndex, 1);
      expect(session.players, hasLength(2));
      expect(_chrome(tester).autoAdvance, isFalse);
      await _unmount(tester);
    },
  );

  testWidgets(
    'settings toggles persist the final choice across page reentry without restarting playback',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      final player = session.players.single;
      await tester.tap(find.byTooltip('播放设置'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('player-auto-advance'));
      for (var i = 0; i < 3; i++) {
        await tester.tap(toggle);
        await tester.pump();
      }
      expect(find.text('本集播完停止'), findsOneWidget);
      await _flush(tester);
      expect(await PlayerPreferences.loadAutoAdvance(), isFalse);
      expect(player.calls.where((call) => call == 'play'), hasLength(1));
      expect(player.calls.where((call) => call == 'pause'), isEmpty);
      expect(session.players, hasLength(1));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await _unmount(tester);
      final reopened = _Session();
      await _mount(tester, reopened);
      expect(_chrome(tester).autoAdvance, isFalse);
      await reopened.players.single.pause();
      reopened.players.single.emitCompleted();
      await _flush(tester);
      expect(reopened.players, hasLength(1));
      await _unmount(tester);
    },
  );

  testWidgets('turning off clears completion waiting for paging to settle', (
    tester,
  ) async {
    final session = _Session();
    await _mount(tester, session);
    _chrome(tester).onPagingChanged!(true);
    session.players.single.emitCompleted();
    _chrome(tester).onAutoAdvanceChanged!(false);
    _chrome(tester).onPagingChanged!(false);
    await _flush(tester);
    expect(_chrome(tester).currentIndex, 0);
    expect(session.players, hasLength(1));
    _chrome(tester).onAutoAdvanceChanged!(true);
    await _flush(tester);
    expect(session.players, hasLength(1));
    expect(await PlayerPreferences.loadAutoAdvance(), isTrue);
    await _unmount(tester);
  });

  testWidgets(
    'play at the end restarts this episode from zero before playing',
    (tester) async {
      SharedPreferences.setMockInitialValues({'player_auto_advance': false});
      final session = _Session();
      await _mount(tester, session);
      final player = session.players.single;
      await player.pause();
      player.emitCompleted();
      await _flush(tester);
      player.calls.clear();
      await tester.tap(find.byTooltip('播放'));
      await _flush(tester);
      expect(player.calls, containsAllInOrder(['seek:0ms', 'play']));
      expect(player.position, Duration.zero);
      expect(session.players, hasLength(1));
      await _unmount(tester);
    },
  );

  testWidgets(
    'backgrounding during a pending restart cannot start playback later',
    (tester) async {
      SharedPreferences.setMockInitialValues({'player_auto_advance': false});
      final session = _Session();
      await _mount(tester, session);
      final player = session.players.single;
      await player.pause();
      player.emitCompleted();
      await _flush(tester);
      final seek = Completer<void>();
      player.seekGate = seek;
      player.calls.clear();
      try {
        await tester.tap(find.byTooltip('播放'));
        await tester.pump();
        expect(player.calls, contains('seek:0ms'));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        seek.complete();
        await _flush(tester);
        expect(player.calls, isNot(contains('play')));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _flush(tester);
        expect(player.calls, isNot(contains('play')));
      } finally {
        if (!seek.isCompleted) seek.complete();
        await _unmount(tester);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
  );
}

VideoPlayerChrome _chrome(WidgetTester tester) =>
    tester.widget<VideoPlayerChrome>(find.byType(VideoPlayerChrome));

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump();
}

Future<void> _mount(WidgetTester tester, _Session session) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() async {
    await _unmount(tester);
    await tester.binding.setSurfaceSize(null);
  });
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _flush(tester);
}

class _Session {
  final players = <ControlledNativePlayer>[];
  final store = MemoryReaderStore();

  Widget app() => MaterialApp(
    home: PlayerPage(
      bookId: 'series-controls',
      title: '测试短剧',
      eps: List.generate(
        3,
        (index) => Chapter(
          itemId: '$index',
          title: '第 ${index + 1} 集',
          volumeName: '',
        ),
      ),
      startIndex: 0,
      description: '剧情介绍',
      historyStore: store,
      contentLoader: (episode) async => {
        'video_url': 'https://example.invalid/${episode.itemId}.mp4',
      },
      playerFactory: () {
        final player = ControlledNativePlayer();
        players.add(player);
        return player;
      },
    ),
  );
}
