import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/pages/system_tts_settings_page.dart';
import 'package:fqapp/services/audio_floating_routes.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/system_tts.dart';
import 'package:fqapp/widgets/reader/reader_listen_capsule.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/controlled_player.dart';

/// 阅读页菜单里那颗胶囊（`ReaderListenCapsuleHost`）的规矩：
///
/// * 三点：朗读中给朗读设置，暂停/没在播给「选择播放引擎」——暂停时用户多
///   半是要换一套来源重听，以前无条件跳设置页等于把「换引擎」藏起来了。
/// * 选完引擎立即接续：暂停的会话按新引擎接着播，不再让用户关掉重进。
/// * 封面：回到书页。菜单就长在书页上，收起菜单即可，不另开控制页。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const more = ValueKey('reader-menu-more');
  const open = ValueKey('reader-menu-open');
  const toggle = ValueKey('reader-menu-toggle');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('fqapp/system_tts');
  const events = MethodChannel('fqapp/system_tts_events');
  const nativePlayer = MethodChannel('fqapp/native_player');
  final ttsCalls = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
    ttsCalls.clear();
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(nativePlayer, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      ttsCalls.add(call.method);
      return call.method == 'initialize' ? 4000 : null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(nativePlayer, null);
  });

  testWidgets('朗读中三点给朗读设置', (tester) async {
    final app = await _mount(tester);
    await _startTts(app, tester);

    await tester.tap(find.byKey(more));
    await _flush(tester);
    expect(find.byType(SystemTtsSettingsPage), findsOneWidget);
    expect(find.text('选择播放引擎'), findsNothing);
  });

  testWidgets('暂停后三点给选择播放引擎，不再是设置页', (tester) async {
    final app = await _mount(tester);
    await _startTts(app, tester);

    await tester.tap(find.byKey(toggle));
    await _flush(tester);

    await tester.tap(find.byKey(more));
    await _flush(tester);
    expect(find.text('选择播放引擎'), findsOneWidget);
    expect(find.byType(SystemTtsSettingsPage), findsNothing);
  });

  testWidgets('点封面回书页：不叠控制页，也不叠第二个书页', (tester) async {
    final app = await _mount(tester);
    await _startTts(app, tester);

    await tester.tap(find.byKey(open));
    await _flush(tester);
    expect(app.openBookCalls, 1);
    expect(find.byType(ReaderPage), findsNothing);
    expect(find.byType(SystemTtsSettingsPage), findsNothing);
  });

  testWidgets('暂停切到智能朗读：TTS 关掉，同一本书起作品音频', (tester) async {
    AudioPage? captured;
    AudioPlaybackScope.startListeningOverride = (context, request) async {
      captured = request;
      return true;
    };
    addTearDown(() => AudioPlaybackScope.startListeningOverride = null);

    final app = await _mount(tester);
    await _startTts(app, tester);
    await tester.tap(find.byKey(toggle));
    await _flush(tester);

    await tester.tap(find.byKey(more));
    await _flush(tester);
    await tester.tap(find.text('智能朗读'));
    await _flush(tester);

    expect(AudioPreferences.instance.listenEngine.value, ListenEngine.smart);
    // 接续请求交给后台起播：同一本书、同一个起点。
    expect(captured, isNotNull);
    expect(captured!.bookId, 'local:book');
    expect(captured!.chapters.single.itemId, 'c1');
    expect(captured!.startIndex, 0);
    // 旧 TTS 会话已经被关掉，胶囊不再挂系统朗读。
    expect(find.byKey(toggle), findsNothing);
  });

  testWidgets('暂停选回系统朗读：接着念，不用重进', (tester) async {
    final app = await _mount(tester);
    await _startTts(app, tester);
    await tester.tap(find.byKey(toggle));
    await _flush(tester);

    await tester.tap(find.byKey(more));
    await _flush(tester);
    await tester.tap(find.text('系统朗读'));
    await _flush(tester);

    expect(AudioPreferences.instance.listenEngine.value, ListenEngine.system);
    // 恢复朗读：引擎重新开口（speak），而不是只记了个偏好。
    expect(ttsCalls, contains('speak'));
  });

  testWidgets('音频暂停选回智能朗读：接着播，不用重进', (tester) async {
    final player = ControlledNativePlayer();
    final app = await _mount(tester);
    await _startAudio(app, tester, player);
    await tester.tap(find.byKey(toggle));
    await _flush(tester);
    player.calls.clear();

    await tester.tap(find.byKey(more));
    await _flush(tester);
    await tester.tap(find.text('智能朗读'));
    await _flush(tester);

    expect(AudioPreferences.instance.listenEngine.value, ListenEngine.smart);
    expect(player.calls, contains('play'));
  });

  testWidgets('音频暂停切系统朗读：有阅读页通道就交给阅读页', (tester) async {
    var switches = 0;
    final player = ControlledNativePlayer();
    final app = await _mount(
      tester,
      home: _SwitcherHost(
        bookId: 'audio:book',
        onSwitch: () async => switches++,
      ),
    );
    await _startAudio(app, tester, player);
    await tester.tap(find.byKey(toggle));
    await _flush(tester);

    await tester.tap(find.byKey(more));
    await _flush(tester);
    await tester.tap(find.text('系统朗读'));
    await _flush(tester);

    expect(switches, 1);
    expect(AudioPreferences.instance.listenEngine.value, ListenEngine.system);
  });

  testWidgets('音频暂停切系统朗读、阅读页不在场：只记偏好并提示', (tester) async {
    final player = ControlledNativePlayer();
    final app = await _mount(tester);
    await _startAudio(app, tester, player);
    await tester.tap(find.byKey(toggle));
    await _flush(tester);
    player.calls.clear();

    await tester.tap(find.byKey(more));
    await _flush(tester);
    await tester.tap(find.text('系统朗读'));
    await _flush(tester);

    expect(AudioPreferences.instance.listenEngine.value, ListenEngine.system);
    // 会话原样暂停在那里，没有假装切成功。
    expect(player.calls, isNot(contains('play')));
    expect(find.textContaining('回书页'), findsOneWidget);
  });
}

Future<void> _startTts(_Harness app, WidgetTester tester) async {
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
}

Future<void> _startAudio(
  _Harness app,
  WidgetTester tester,
  ControlledNativePlayer player,
) async {
  await ReaderAudioBridge.startListeningInBackground(
    app.navigator.currentContext!,
    AudioPage(
      bookId: 'audio:book',
      title: 'Audio book',
      chapters: [Chapter(itemId: 'a1', title: 'Chapter', volumeName: '')],
      startIndex: 0,
      sourceLoader: (id, {toneId}) async => AudioSource(
        itemId: id,
        url: 'https://example.invalid/a.mp3',
        toneId: toneId ?? '0',
      ),
      voicesLoader: () async => const [],
      subtitleLoader: (id, toneId) async =>
          SubtitleTrack([SubtitleCue(startMs: 0, text: '第一段。')]),
      playerFactory: () => player,
    ),
  );
  await _flush(tester);
}

Future<_Harness> _mount(WidgetTester tester, {Widget? home}) async {
  final app = _Harness();
  final routes = AudioFloatingRoutes(defaultBottomInset: 0);
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
          child: child!,
        ),
      ),
      home:
          home ??
          Scaffold(
            body: ReaderListenCapsuleHost(
              monochrome: false,
              onOpenBook: () => app.openBookCalls++,
            ),
          ),
    ),
  );
  await _flush(tester);
  return app;
}

/// 模拟阅读页：把「换引擎接续」通道挂进胶囊的祖先链。
class _SwitcherHost extends StatelessWidget {
  const _SwitcherHost({required this.bookId, required this.onSwitch});

  final String bookId;
  final Future<void> Function() onSwitch;

  @override
  Widget build(BuildContext context) => ReaderEngineSwitch(
    bookId: bookId,
    onSwitch: onSwitch,
    child: Scaffold(
      body: ReaderListenCapsuleHost(monochrome: false),
    ),
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

class _Harness {
  final navigator = GlobalKey<NavigatorState>();
  int openBookCalls = 0;
}
