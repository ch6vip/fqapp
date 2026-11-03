import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// 阅读页菜单里那颗胶囊（`ReaderListenCapsuleHost`）的两条规矩：
///
/// * 三点：朗读中给朗读设置，暂停/没在播给「选择播放引擎」——暂停时用户多
///   半是要换一套来源重听，以前无条件跳设置页等于把「换引擎」藏起来了。
/// * 封面：回到书页。菜单就长在书页上，收起菜单即可，不另开控制页。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const more = ValueKey('audio-floating-more');
  const open = ValueKey('audio-floating-open');
  const toggle = ValueKey('audio-floating-toggle');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('fqapp/system_tts');
  const events = MethodChannel('fqapp/system_tts_events');
  const nativePlayer = MethodChannel('fqapp/native_player');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(nativePlayer, (_) async => null);
    messenger.setMockMethodCallHandler(
      methods,
      (call) async => call.method == 'initialize' ? 4000 : null,
    );
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

Future<_Harness> _mount(WidgetTester tester) async {
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
      home: Scaffold(
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
