import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/audio_floating_routes.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/system_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';

/// The app-wide capsule, official GlobalPlayerView (`hm.xml`, id `dk5`).
///
/// Each case follows a rule read from the 7.0.9.32 decompilation: which pages
/// show it (`fe3/t.java` deny-list), where it sits (`pn2/t.java`), and what
/// its buttons do (`pn2/b0.java`, `pn2/i.java`).
void main() {
  const open = ValueKey('audio-floating-open');
  const toggle = ValueKey('audio-floating-toggle');
  const close = ValueKey('audio-floating-close');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
  });

  testWidgets('hides on the listening page and returns after leaving it', (
    tester,
  ) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    expect(find.byKey(toggle), findsNothing);

    app.navigator.currentState!.pop();
    await _flush(tester);
    expect(find.byKey(toggle), findsOneWidget);
    expect(app.players.single.isPlaying, isTrue);
  });

  testWidgets('a dialog covers the capsule without detaching it', (
    tester,
  ) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.navigator.currentState!.pop();
    await _flush(tester);
    final at = tester.getCenter(find.byKey(toggle));

    unawaited(
      showDialog<void>(
        context: app.navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('对话框')),
      ),
    );
    await _flush(tester);
    // Official: the ball stays attached under the dialog window.
    expect(find.byKey(toggle), findsOneWidget);

    // The barrier sits above it, so the tap dismisses the dialog instead.
    await tester.tapAt(at);
    await _flush(tester);
    expect(app.players.single.isPlaying, isTrue);
    expect(find.text('对话框'), findsNothing);
  });

  testWidgets('popping a nested dialog keeps the capsule under the other', (
    tester,
  ) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.navigator.currentState!.pop();
    await _flush(tester);
    final at = tester.getCenter(find.byKey(toggle));
    for (final text in ['外层', '内层']) {
      unawaited(
        showDialog<void>(
          context: app.navigator.currentContext!,
          builder: (_) => AlertDialog(content: Text(text)),
        ),
      );
      await _flush(tester);
    }
    // Finalizing the inner pop rearranges the Overlay once more.
    app.navigator.currentState!.pop();
    await _flush(tester);
    expect(find.text('外层'), findsOneWidget);

    await tester.tapAt(at);
    await _flush(tester);
    expect(app.players.single.isPlaying, isTrue);
    expect(find.text('外层'), findsNothing);
  });
  testWidgets('a page can opt out, like the reader and the image viewer', (
    tester,
  ) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.navigator.currentState!.pop();
    await _flush(tester);

    app.push(
      Builder(
        builder: (context) {
          AudioFloatingRouteScope.configure(context, hidden: true);
          return const Scaffold(body: Text('大图'));
        },
      ),
    );
    await _flush(tester);
    expect(find.byKey(toggle), findsNothing);

    app.navigator.currentState!.pop();
    await _flush(tester);
    expect(find.byKey(toggle), findsOneWidget);
  });

  testWidgets('every page clears the default bottom inset', (tester) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.navigator.currentState!.pop();
    await _flush(tester);
    // 932 - 50 high - 18dp margin - 72 default inset.
    expect(tester.getRect(find.byKey(toggle)).bottom, 932 - 18 - 72);

    // Official tabbar + 18dp applies on pages without a tab bar too.
    app.push(const Scaffold(body: Text('详情')));
    await _flush(tester);
    expect(tester.getRect(find.byKey(toggle)).bottom, 932 - 18 - 72);

    app.push(
      Builder(
        builder: (context) {
          AudioFloatingRouteScope.configure(context, bottomInset: 0);
          return const Scaffold(body: Text('无底栏'));
        },
      ),
    );
    await _flush(tester);
    expect(tester.getRect(find.byKey(toggle)).bottom, 932 - 18);
  });

  testWidgets('the cover returns to a live listening page instead of a copy', (
    tester,
  ) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.push(const Scaffold(body: Text('详情')));
    await _flush(tester);

    await tester.tap(find.byKey(open));
    await _flush(tester);
    expect(find.text('详情'), findsNothing);
    expect(find.byType(AudioPage), findsOneWidget);
    expect(app.players, hasLength(1));
  });

  testWidgets('the cover reopens the session when no page is alive', (
    tester,
  ) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.players.single.emitPosition(const Duration(seconds: 21));
    app.navigator.currentState!.pop();
    await _flush(tester);

    await tester.tap(find.byKey(open));
    await _flush(tester);
    expect(find.byType(AudioPage), findsOneWidget);
    expect(app.players, hasLength(1));
    expect(app.players.single.position, const Duration(seconds: 21));
  });

  testWidgets('closing stops playback and drops the stale listening page', (
    tester,
  ) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.push(const Scaffold(body: Text('详情')));
    await _flush(tester);

    await tester.tap(find.byKey(close));
    await tester.pump(const Duration(milliseconds: 350));
    await _flush(tester);
    expect(app.players.single.disposed, isTrue);
    expect(find.byKey(toggle), findsNothing);

    // A page below would show a closed session it can never restart.
    app.navigator.currentState!.pop();
    await _flush(tester);
    expect(find.byType(AudioPage), findsNothing);
    expect(find.text('书架'), findsOneWidget);
  });

  testWidgets('buffering keeps pause available, as on the listening page', (
    tester,
  ) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.navigator.currentState!.pop();
    await _flush(tester);
    app.players.single.emitBuffering(true);
    await _flush(tester);

    await tester.tap(find.byKey(toggle));
    await _flush(tester);
    expect(app.players.single.isPlaying, isFalse);
  });

  testWidgets('an error toasts once and the play button retries', (
    tester,
  ) async {
    final app = await _mount(tester);
    app.open();
    await _flush(tester);
    app.navigator.currentState!.pop();
    await _flush(tester);
    app.players.single.emitPosition(const Duration(seconds: 12));
    app.players.single.errors.add(StateError('decoder'));
    await _flush(tester);
    expect(find.text('播放出错，请稍后重试'), findsOneWidget);
    expect(find.byKey(toggle), findsOneWidget);

    await tester.tap(find.byKey(toggle));
    await _flush(tester);
    expect(app.players, hasLength(2));
    expect(app.players.last.isPlaying, isTrue);
    expect(app.players.last.position, const Duration(seconds: 12));
  });
  testWidgets('system TTS plays through the same capsule', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const methods = MethodChannel('fqapp/system_tts');
    const events = MethodChannel('fqapp/system_tts_events');
    const nativePlayer = MethodChannel('fqapp/native_player');
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(nativePlayer, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return call.method == 'initialize' ? 4000 : null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(events, null);
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(nativePlayer, null);
    });

    final app = await _mount(tester);
    await AudioPlaybackScope.startSystemTts(
      app.navigator.currentContext!,
      SystemTtsBook(
        bookId: 'local:book',
        title: 'Local book',
        chapters: [Chapter(itemId: 'c1', title: 'Chapter', volumeName: '')],
        startIndex: 0,
        localOnly: true,
        initialContent: ChapterContent.fromPlainText('A sentence to speak.'),
      ),
    );
    await _flush(tester);
    // Officially TTS is an ordinary session: no separate bottom bar.
    expect(find.byKey(toggle), findsOneWidget);
    expect(find.text('Local book'), findsNothing);

    calls.clear();
    await tester.tap(find.byKey(toggle));
    await _flush(tester);
    expect(calls.any((call) => call.method == 'stop'), isTrue);
    expect(ListeningSession.instance.playing, isFalse);

    await tester.tap(find.byKey(close));
    await tester.pump(const Duration(milliseconds: 350));
    await _flush(tester);
    expect(find.byKey(toggle), findsNothing);
  });

  testWidgets('a cold start offers the last listened book on the home shell', (
    tester,
  ) async {
    final app = await _mount(
      tester,
      recent: (app) => RecentListen(
        bookId: 'book',
        title: 'book',
        cover: '',
        progress: .5,
        request: () async => app.page(),
      ),
    );
    await _flush(tester);
    expect(find.byKey(toggle), findsOneWidget);
    expect(app.players, isEmpty);

    // Only the home shell attaches the idle ball (`recentread/j0.java`).
    app.push(const Scaffold(body: Text('详情')));
    await _flush(tester);
    expect(find.byKey(toggle), findsNothing);
    app.navigator.currentState!.pop();
    await _flush(tester);

    await tester.tap(find.byKey(toggle));
    await _flush(tester);
    expect(app.players, hasLength(1));
    expect(app.players.single.isPlaying, isTrue);
    expect(find.byType(AudioPage), findsNothing);
    expect(find.byKey(toggle), findsOneWidget);
  });

  testWidgets('closing the idle capsule keeps it closed', (tester) async {
    final app = await _mount(
      tester,
      recent: (app) => RecentListen(
        bookId: 'book',
        title: 'book',
        cover: '',
        progress: 0,
        request: () async => app.page(),
      ),
    );
    await _flush(tester);
    await tester.tap(find.byKey(close));
    await tester.pump(const Duration(milliseconds: 350));
    await _flush(tester);
    expect(find.byKey(toggle), findsNothing);
    expect(app.players, isEmpty);
  });
}

Future<_Harness> _mount(
  WidgetTester tester, {
  RecentListen Function(_Harness app)? recent,
}) async {
  final app = _Harness();
  final routes = AudioFloatingRoutes(defaultBottomInset: 72);
  await tester.binding.setSurfaceSize(const Size(430, 932));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    routes.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: app.navigator,
      navigatorObservers: [routes],
      builder: (_, child) => AudioFloatingRouteScope(
        routes: routes,
        child: AudioPlaybackScope(
          navigatorKey: app.navigator,
          recentListen: recent == null ? null : () async => recent(app),
          child: child!,
        ),
      ),
      home: const Scaffold(body: Text('书架')),
    ),
  );
  return app;
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  // Route transitions advance per frame, not per elapsed time.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

class _Harness {
  final navigator = GlobalKey<NavigatorState>();
  final store = ControlledReaderStore();
  final players = <ControlledNativePlayer>[];

  void push(Widget page) => unawaited(
    navigator.currentState!.push<void>(MaterialPageRoute(builder: (_) => page)),
  );

  void open() => push(page());

  AudioPage page() => AudioPage(
    bookId: 'book',
    title: 'book',
    chapters: [
      for (var i = 1; i <= 2; i++)
        Chapter(itemId: 'book-$i', title: '第 $i 章', volumeName: ''),
    ],
    historyStore: store,
    sourceLoader: (id, {toneId}) async => AudioSource(
      itemId: id,
      url: 'https://example.invalid/audio.mp3',
      toneId: toneId ?? '0',
    ),
    voicesLoader: () async => const [],
    playerFactory: () {
      final player = ControlledNativePlayer();
      players.add(player);
      return player;
    },
  );
}
