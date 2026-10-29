import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/reader/reader_player_pill.dart';
import 'package:fqapp/widgets/reader/reader_status_bar.dart';

void main() {
  late ValueNotifier<int> viewport;
  setUp(() {
    viewport = ValueNotifier(0);
    ListeningSession.instance.update(
      bookId: 'book',
      chapterId: 'chapter',
      chapterTitle: 'Chapter',
      position: Duration.zero,
      duration: const Duration(minutes: 1),
      playing: true,
    );
  });
  tearDown(() {
    viewport.dispose();
    ListeningSession.instance.clear();
  });

  Future<void> mount(
    WidgetTester tester, {
    double scale = 1,
    bool reducedMotion = false,
    bool statusBar = false,
    ReaderThemePreset preset = ReaderThemePreset.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reducedMotion,
            padding: const EdgeInsets.only(bottom: 24),
          ),
          child: Scaffold(
            body: SafeArea(
              child: ReaderPlayerPillHost(
                bookId: 'book',
                viewportChanges: viewport,
                highlightOnScreen: () => true,
                preset: preset,
                footerBuilder: statusBar
                    ? (player) => ReaderStatusBar(
                        preset: preset,
                        playerControl: player,
                        status: ReaderDeviceStatus(
                          time: DateTime(2026, 10, 28, 12),
                          battery: 64,
                        ),
                        progress: .42,
                        chapterIndex: 0,
                        chapterCount: 20,
                      )
                    : null,
                child: const SizedBox.expand(key: ValueKey('body')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final size in [
    const Size(240, 568),
    const Size(1024, 768),
    const Size(640, 240),
  ]) {
    testWidgets(
      'both hosts fit $size at large text scale and respect safe areas',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await mount(tester, scale: 2.5, statusBar: true);
        final body = tester.getRect(find.byKey(const ValueKey('body')));
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(milliseconds: 350));
        final pill = tester.getRect(
          find.byKey(const ValueKey('reader_player_pill')),
        );
        expect(pill.bottom, lessThanOrEqualTo(size.height - 24));
        expect(pill.left, greaterThanOrEqualTo(0));
        expect(pill.right, lessThanOrEqualTo(size.width));
        expect(pill.top, greaterThanOrEqualTo(body.bottom));
        expect(tester.getRect(find.byKey(const ValueKey('body'))), body);
        expect(
          find.byKey(const ValueKey('reader-player-footer')),
          findsNothing,
        );
        expect(
          pill.center.dy,
          tester.getCenter(find.byKey(const ValueKey('reader-clock'))).dy,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('animated host transition exposes only one accessible action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await mount(tester);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 100));
      var actions = 0;
      void visit(SemanticsNode node) {
        if (node.getSemanticsData().label == '暂停播放') actions++;
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(tester.getSemantics(find.byType(Scaffold)));
      expect(actions, 1);
      final outgoing = find.byKey(const ValueKey('reader-player-indicator'));
      expect(outgoing.hitTestable(), findsNothing);
      await tester.pump(const Duration(milliseconds: 250));
      expect(outgoing, findsNothing);
      expect(find.byKey(const ValueKey('reader-player-text')), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  for (final eink in [false, true]) {
    testWidgets(
      '${eink ? 'eink' : 'reduced motion'} skips fades but keeps the delay',
      (tester) async {
        await mount(
          tester,
          reducedMotion: !eink,
          preset: eink ? ReaderThemePreset.eink : ReaderThemePreset.light,
        );
        await tester.pump(const Duration(seconds: 4));
        expect(
          find.byKey(const ValueKey('reader-player-indicator')),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('reader-player-indicator')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('reader-player-text')),
          findsOneWidget,
        );
      },
    );
  }
}
