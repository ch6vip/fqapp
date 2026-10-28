import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/system_tts.dart';
import 'package:fqapp/widgets/reader/reader_player_pill.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('fqapp/system_tts');
  const events = MethodChannel('fqapp/system_tts_events');
  const player = MethodChannel('fqapp/native_player');
  late List<MethodCall> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
    calls = [];
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(player, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return call.method == 'initialize' ? 4000 : null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(player, null);
  });

  testWidgets(
    'reader capsule pauses and resumes the real system TTS controller',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final navigator = GlobalKey<NavigatorState>();
      final viewport = ValueNotifier(0);
      late BuildContext readerContext;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (_, child) =>
              AudioPlaybackScope(navigatorKey: navigator, child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                readerContext = context;
                return ReaderPlayerPillHost(
                  bookId: 'local:book',
                  viewportChanges: viewport,
                  highlightOnScreen: () => true,
                  animate: false,
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        ),
      );
      await AudioPlaybackScope.startSystemTts(
        readerContext,
        SystemTtsBook(
          bookId: 'local:book',
          title: 'Local book',
          chapters: [Chapter(itemId: 'c1', title: 'Chapter', volumeName: '')],
          startIndex: 0,
          localOnly: true,
          initialContent: ChapterContent.fromPlainText('A sentence to speak.'),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(ListeningSession.instance.playing, isTrue);
      expect(calls.where((call) => call.method == 'speak'), isNotEmpty);
      expect(
        AudioPlaybackScope.togglePlayback(readerContext, 'another-book'),
        isFalse,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.byKey(const ValueKey('reader-player-text')), findsOneWidget);
      calls.clear();
      await tester.tap(find.byKey(const ValueKey('reader_player_pill')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(calls.any((call) => call.method == 'stop'), isTrue);
      expect(ListeningSession.instance.playing, isFalse);
      expect(find.text('继续播放'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-player-indicator')),
        findsOneWidget,
      );
      calls.clear();
      await tester.tap(find.byKey(const ValueKey('reader_player_pill')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(calls.any((call) => call.method == 'speak'), isTrue);
      expect(ListeningSession.instance.playing, isTrue);
      expect(find.text('暂停播放'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      viewport.dispose();
    },
  );
}
