import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/widgets/audio/audio_sections.dart';
import 'package:fqapp/widgets/detail/detail_read_bar.dart';

import 'support/controlled_player.dart';

const _related = RelatedWork(kind: 'book', id: 'novel', title: '关联原著');

void main() {
  setUpAll(() async {
    // Initialize this isolate's shared API with an offline HTTP client. The
    // related-work route still builds its real DetailPage and listening entry.
    final api = http.runWithClient(
      () => ApiClient.instance,
      () => MockClient((request) async {
        final data = request.url.path == '/api/directory'
            ? {
                'chapterListWithVolume': [
                  [
                    {'itemId': 'novel-1', 'title': '原著第一章'},
                  ],
                ],
              }
            : <String, Object>{};
        return http.Response(
          jsonEncode({'code': 0, 'data': data}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    expect(
      (await api.directoryChapters('novel')).single.single.itemId,
      'novel-1',
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    ListeningSession.instance.clear();
  });

  testWidgets(
    'related work releases narration and returns at the paused position',
    (tester) async {
      final session = _Session();
      await _mount(tester, session);
      final original = session.players.single;
      original.emitPosition(const Duration(milliseconds: 37500));
      _openRelated(tester);
      await _flush(tester);
      expect(original.disposed, isTrue);
      expect(original.isPlaying, isFalse);
      expect(session.store.entry?['position'], 37.5);
      expect(ListeningSession.instance.playing, isFalse);
      expect(find.byType(DetailPage), findsOneWidget);
      await _waitFor(tester, find.byType(DetailReadBar));
      expect(
        tester.widget<DetailReadBar>(find.byType(DetailReadBar)).onListen,
        isNotNull,
      );

      session.navigator.currentState!.pop();
      await _flush(tester);
      expect(session.players, hasLength(2));
      expect(
        session.players.last.position,
        const Duration(milliseconds: 37500),
      );
      expect(session.players.last.isPlaying, isFalse);
      expect(find.byType(DetailPage), findsNothing);
    },
  );

  testWidgets(
    'repeated related-work taps wait for one native release and one route',
    (tester) async {
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final session = _Session(
        firstPlayer: ControlledNativePlayer(releaseGate: release),
      );
      await _mount(tester, session);
      final row = tester.widget<AudioRelatedRow>(find.byType(AudioRelatedRow));
      row.onTap(_related);
      row.onTap(_related);
      await _flush(tester);
      expect(session.pushes.detailRoutes, 0);
      release.complete();
      await _flush(tester);
      expect(session.pushes.detailRoutes, 1);
      expect(find.byType(DetailPage, skipOffstage: false), findsOneWidget);
      session.navigator.currentState!.pop();
      await _flush(tester);
      expect(session.players.last.isPlaying, isFalse);
    },
  );

  testWidgets('a pause failure still releases before related-work navigation', (
    tester,
  ) async {
    final original = _PauseFailurePlayer();
    final session = _Session(firstPlayer: original);
    await _mount(tester, session);
    original.failPause = true;
    _openRelated(tester);
    await _flush(tester);
    expect(original.disposed, isTrue);
    expect(find.byType(DetailPage), findsOneWidget);
    session.navigator.currentState!.pop();
    await _flush(tester);
    expect(session.players, hasLength(2));
    expect(session.players.last.isPlaying, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a chapter chosen during release supersedes the related route', (
    tester,
  ) async {
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final session = _Session(
      firstPlayer: ControlledNativePlayer(releaseGate: release),
    );
    await _mount(tester, session);
    _openRelated(tester);
    await _flush(tester);
    await tester.tap(find.byTooltip('下一章'));
    await _flush(tester);
    release.complete();
    await _flush(tester);
    expect(session.pushes.detailRoutes, 0);
    expect(session.players, hasLength(2));
    expect(session.players.last.isPlaying, isTrue);
    expect(session.store.entry?['chapterId'], '2');
  });

  testWidgets(
    'a source finishing under the related route cannot start narration',
    (tester) async {
      final source = Completer<AudioSource>();
      var requests = 0;
      final session = _Session(
        sourceLoader: (itemId, {toneId}) =>
            requests++ == 0 ? source.future : Future.value(_source(itemId)),
      );
      await _mount(tester, session);
      expect(session.players, isEmpty);
      _openRelated(tester);
      await _flush(tester);
      expect(find.byType(DetailPage), findsOneWidget);
      source.complete(_source('1'));
      await _flush(tester);
      expect(session.players, isEmpty);
      session.navigator.currentState!.pop();
      await _flush(tester);
      expect(session.players, hasLength(1));
      expect(session.players.single.isPlaying, isFalse);
    },
  );
}

void _openRelated(WidgetTester tester) {
  tester.widget<AudioRelatedRow>(find.byType(AudioRelatedRow)).onTap(_related);
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 50 && !tester.any(finder); i++) {
    await _flush(tester);
  }
  expect(finder, findsOneWidget);
}

Future<void> _mount(WidgetTester tester, _Session session) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(session.app());
  await _flush(tester);
}

AudioSource _source(String itemId) => AudioSource(
  itemId: itemId,
  url: 'https://cdn.example/$itemId.m4a',
  toneId: '0',
);

class _Session {
  final ControlledNativePlayer? firstPlayer;
  final Future<AudioSource> Function(String, {String? toneId})? sourceLoader;
  final store = ControlledReaderStore();
  final players = <ControlledNativePlayer>[];
  final navigator = GlobalKey<NavigatorState>();
  final pushes = _RouteObserver();

  _Session({this.firstPlayer, this.sourceLoader});

  Widget app() => MaterialApp(
    navigatorKey: navigator,
    navigatorObservers: [pushes],
    home: AudioPage(
      bookId: 'recording',
      title: '原录音',
      chapters: [
        Chapter(itemId: '1', title: '第一章', volumeName: ''),
        Chapter(itemId: '2', title: '第二章', volumeName: ''),
      ],
      historyStore: store,
      playerFactory: () {
        final player = players.isEmpty && firstPlayer != null
            ? firstPlayer!
            : ControlledNativePlayer();
        players.add(player);
        return player;
      },
      voicesLoader: () async => const [AudioVoice(id: '0', label: '默认音色')],
      sourceLoader: sourceLoader ?? (itemId, {toneId}) async => _source(itemId),
      extrasLoader: (_) async => const AudioExtras(related: [_related]),
    ),
  );
}

class _RouteObserver extends NavigatorObserver {
  int detailRoutes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) detailRoutes++;
  }
}

class _PauseFailurePlayer extends ControlledNativePlayer {
  bool failPause = false;

  @override
  Future<void> pause() async {
    if (failPause) throw StateError('platform pause acknowledgement failed');
    await super.pause();
  }
}
