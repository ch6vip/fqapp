import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';

import 'support/fakes.dart';

/// `ReaderPage(embedded: true)` renders inside the listening page instead of
/// owning the screen.
///
/// 官方 `AudioTextTabFragment` puts the reader in the listening page and keeps
/// the transport controls below it, so the embedded form must not install its
/// own Scaffold, PopScope or system-bar styling — the host owns those, and
/// wrapping twice makes the status bar flip between two colour sets.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpReader(
    WidgetTester tester, {
    required bool embedded,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        // A host page: the embedded reader must not add a second Scaffold.
        home: Scaffold(
          body: ReaderPage(
            bookId: 'embedded',
            title: '内嵌测试',
            chapters: [
              Chapter(itemId: '1', title: '第 1 章', volumeName: ''),
            ],
            startIndex: 0,
            embedded: embedded,
            readerStore: MemoryReaderStore(),
            chapterCache: MemoryChapterCache(),
            chapterLoader: (_) async => '第 1 章\n\n用于核查内嵌形态的正文。',
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('embedded reader', () {
    testWidgets('adds no Scaffold of its own inside the host', (tester) async {
      await pumpReader(tester, embedded: true);
      // Exactly one: the host's. A second one would carry its own
      // background and fight the listening page.
      expect(find.byType(Scaffold), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the standalone form still owns its Scaffold', (tester) async {
      await pumpReader(tester, embedded: false);
      // Host + reader's own.
      expect(find.byType(Scaffold), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the chapter text in both forms', (tester) async {
      for (final embedded in [true, false]) {
        await pumpReader(tester, embedded: embedded);
        expect(
          find.byKey(const ValueKey('reader-page-surface')),
          findsOneWidget,
          reason: 'embedded=$embedded must still render the page surface',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });

  group('paging reflows to a short panel', () {
    test('a short viewport splits pages without dropping text', () {
      final tall = _layoutAt(const Size(360, 900));
      final short = _layoutAt(const Size(360, 240));
      // The embedded panel is far shorter than a full screen; paging measures
      // `constraints.biggest`, so it must reflow rather than overflow.
      expect(
        short.blocks.map((b) => b.text).join(),
        tall.blocks.map((b) => b.text).join(),
      );
      expect(short.pages.length, greaterThanOrEqualTo(tall.pages.length));
      for (final page in short.pages) {
        expect(page.height, lessThanOrEqualTo(240));
      }
    });
  });
}

ReaderChapterLayout _layoutAt(Size viewport) {
  final spec = ReaderLayoutSpec(
    viewport: viewport,
    textScaler: TextScaler.noScaling,
    preferences: const ReaderPreferences(),
    fontFamily: null,
  );
  return ReaderChapterLayout(
    title: '第1章 上门退婚',
    content: parseChapterContent(
      '<p idx="0">第1章 上门退婚</p>'
      '<p idx="1">竹溪村一个破旧的院子里，一个二十几岁的青年，'
      '拉着一个美少妇的手不停地晃悠，口里还可恰兮兮地说道。</p>'
      '<p idx="3">秀玲嫂子，我要吃又白又大的馒头。</p>',
    ),
    spec: spec,
  );
}
