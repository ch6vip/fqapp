import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/ai_reading/feedback/ai_missed_sheet.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/ai_reading/ai_chapter_snapshot.dart';
import 'package:fqapp/services/ai_reading/ai_controller.dart';
import 'package:fqapp/services/ai_reading/ai_models.dart';
import 'package:fqapp/services/ai_reading/ai_settings.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/text_replacement_engine.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/reader/reader_chapter_layout.dart';
import 'package:fqapp/widgets/reader/reader_controls.dart';
import 'package:fqapp/widgets/reader/reader_joined_scroll.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_paragraph_menu.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/fakes.dart';

final _chapters = [
  Chapter(itemId: 'a', title: '甲章', volumeName: ''),
  Chapter(itemId: 'b', title: '乙章', volumeName: ''),
];
final _textA = List.generate(
  30,
  (i) => '甲章段落${i.toString().padLeft(2, '0')}：甲城的风吹过甲家的窗，甲舟停在岸边。',
).join('\n');
final _textB = _textA.replaceAll('甲', '乙');
final _snapshotA = _snapshot(_textA, _chapters[0].title);
final _snapshotB = _snapshot(_textB, _chapters[1].title);

void main() {
  setUp(() {
    setSingleChapterPrefs({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    // Do not initialize Hive, the controller, settings, or credentials. These
    // regressions exercise read-only composition with cloud consent absent.
    expect(AiSettingsStore.instance.device.cloudConsent, isFalse);
    expect(AiReadingController.instance.isReady, isFalse);
  });

  testWidgets(
    'temporary original A to B gives missed feedback the B snapshot',
    (tester) async {
      const bookId = 'local:ai-merge-original';
      await _prepare(tester, bookId: bookId);
      await _enableAi(bookId);
      await tester.pumpWidget(_app(_reader(bookId)));
      await tester.pumpAndSettle();
      expect(_pager(tester).layout.blocks[1].text, _snapshotA.paragraphs.first);

      final toggle = await _openAiPanel(tester);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await _closePanel(tester, toggle);

      final controls = _controls(tester);
      expect(controls.onNext, isNotNull);
      controls.onNext!();
      await tester.pumpAndSettle();
      expect(_controls(tester).chapterIndex, 1);
      expect(_pager(tester).layout.blocks[1].text, _snapshotB.paragraphs.first);
      final bToggle = await _openAiPanel(tester);
      expect(tester.widget<SwitchListTile>(bToggle).value, isTrue);
      await _closePanel(tester, bToggle);

      await _openMissed(tester);
      _expectBSnapshot(tester, bookId);
      await _closePanel(tester, find.byType(AiMissedSheet));
      expect(AiSettingsStore.instance.device.cloudConsent, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'joined adoption carries the B AI view with its content and layout',
    (tester) async {
      const bookId = 'local:ai-merge-joined';
      await _prepare(tester, bookId: bookId);
      setSingleChapterPrefs({
        'reader_page_mode': 'scroll',
        'reader_scroll_chapter_mode': 'joined',
      });
      await _enableAi(bookId);
      await tester.pumpWidget(_app(_reader(bookId)));
      await tester.pumpAndSettle();
      final joinedFinder = find.byType(ReaderJoinedScroll);
      final state = tester.state<ReaderJoinedScrollState>(joinedFinder);
      expect(
        state.chapterAt(0)!.aiView!.snapshot.canonicalHash,
        _snapshotA.canonicalHash,
      );
      final neighbor = state.chapterAt(1);
      expect(
        neighbor,
        isNotNull,
        reason: 'The real joined loader must preload B.',
      );
      final view = neighbor!.aiView;
      expect(view, isNotNull);
      expect(view!.bookId, bookId);
      expect(view.chapterId, 'b');
      expect(view.snapshot.requestText, _snapshotB.requestText);
      expect(view.snapshot.canonicalHash, _snapshotB.canonicalHash);
      expect(view.composition.replacement.source, same(neighbor.content));
      expect(neighbor.displayRevision, view.composition.displayRevision);
      expect(view.consent, isFalse);
      final relaid = neighbor.withLayout(
        ReaderChapterLayout(
          title: _chapters[1].title,
          content: neighbor.content,
          replacement: neighbor.replacement,
          spec: neighbor.layout.spec,
        ),
      );
      expect(relaid.aiView, same(view));
      expect(relaid.content, same(neighbor.content));
      expect(relaid.displayRevision, neighbor.displayRevision);

      final scroll = tester.widget<ReaderJoinedScroll>(joinedFinder).controller;
      final bStart = state.chapterStart(1);
      expect(bStart, greaterThan(0));
      expect(bStart, lessThan(scroll.position.maxScrollExtent));
      scroll.jumpTo(bStart);
      // Observe adoption before opening a panel could trigger recomposition.
      await tester.pump();
      await tester.pump();
      final adopted = tester.widget<ReaderJoinedScroll>(joinedFinder);
      expect(adopted.index, 1);
      expect(adopted.chapter.aiView, same(view));
      expect(adopted.chapter.content, same(neighbor.content));
      expect(adopted.chapter.displayRevision, view.composition.displayRevision);
      await tester.pumpAndSettle();
      expect(state.position!.index, 1);
      expect(_controls(tester).chapterIndex, 1);
      final toggle = await _openAiPanel(tester);
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await _closePanel(tester, toggle);
      await _openMissed(tester);
      _expectBSnapshot(tester, bookId);
      await _closePanel(tester, find.byType(AiMissedSheet));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('six Wenku dock callbacks survive with and without optional AI', (
    tester,
  ) async {
    await _prepare(tester, size: const Size(280, 560));
    final calls = <String>[];
    for (final withAi in [false, true]) {
      calls.clear();
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: ReaderControls(
              preferences: const ReaderPreferences(),
              chapterIndex: 0,
              chapterTitle: '甲章',
              fraction: .25,
              animation: const AlwaysStoppedAnimation(1.0),
              previewing: false,
              onPrevious: null,
              onNext: () {},
              onPreview: (_) {},
              onCommitted: (_) {},
              onPreviewChanged: (_) {},
              onDirectory: () => calls.add('catalogue'),
              onBookmarks: () => calls.add('bookmarks'),
              onAppearance: () => calls.add('settings'),
              onOperations: () => calls.add('operations'),
              onFind: () => calls.add('find'),
              onNight: () => calls.add('night'),
              onAi: withAi ? () => calls.add('ai') : null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final key in [
        'reader-catalogue-entry',
        'reader-bookmarks-entry',
        'reader-settings',
        'reader-operations-entry',
        'reader-find-entry',
        'reader-night-entry',
      ]) {
        final action = find.byKey(ValueKey(key));
        expect(action.hitTestable(), findsOneWidget);
        await tester.tap(action);
        await tester.pumpAndSettle();
      }
      final ai = find.byKey(const ValueKey('reader-ai'));
      expect(ai, withAi ? findsOneWidget : findsNothing);
      if (withAi) {
        expect(ai.hitTestable(), findsOneWidget);
        await tester.tap(ai);
        await tester.pumpAndSettle();
      }
      expect(calls, [
        'catalogue',
        'bookmarks',
        'settings',
        'operations',
        'find',
        'night',
        if (withAi) 'ai',
      ]);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'narrow selection bar scrolls to both bookmark and missed change',
    (tester) async {
      const size = Size(240, 400);
      await _prepare(tester, size: size);
      final calls = <ReaderParagraphAction>[];
      final (position, below) = ReaderParagraphMenu.resolvePosition(
        anchor: const Offset(230, 380),
        topAnchor: const Offset(230, 340),
        paragraphScoped: true,
        view: size,
        safeArea: EdgeInsets.zero,
        underlined: false,
        showBookmark: true,
        showAi: true,
      );
      expect(
        ReaderParagraphMenu.itemCount(
          underlined: false,
          paragraphScoped: true,
          showBookmark: true,
          showAi: true,
        ),
        5,
      );
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: position.dx,
                  top: position.dy,
                  child: ReaderParagraphMenu(
                    showBookmark: true,
                    showAi: true,
                    maxWidth: size.width - 20,
                    belowAnchor: below,
                    onAction: calls.add,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester.getRect(
        find.byKey(const ValueKey('reader-selection-glass-bar')),
      );
      expect(bar.left, greaterThanOrEqualTo(10));
      expect(bar.right, lessThanOrEqualTo(size.width - 10));
      expect(bar.top, greaterThanOrEqualTo(10));
      expect(bar.bottom, lessThanOrEqualTo(size.height - 10));
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      for (final key in ['reader-action-bookmark', 'reader-action-missed']) {
        final action = find.byKey(ValueKey(key));
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        expect(action.hitTestable(), findsOneWidget);
        await tester.tap(action);
        await tester.pumpAndSettle();
      }
      expect(calls, [
        ReaderParagraphAction.bookmark,
        ReaderParagraphAction.missedChange,
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}

AiChapterSnapshot _snapshot(String text, String title) =>
    AiChapterSnapshotBuilder.fromContent(
      ChapterContent.fromPlainText(text, illustrationsChecked: true),
      title,
    );

Future<void> _enableAi(String bookId) async {
  expect(_textA.length, _textB.length);
  expect(
    _snapshotA.paragraphBoundaryFingerprint,
    _snapshotB.paragraphBoundaryFingerprint,
  );
  expect(_snapshotA.canonicalHash, isNot(_snapshotB.canonicalHash));
  await AiSettingsStore.instance.setBookOverride(bookId, 'enabled', true);
  expect(AiSettingsStore.instance.resolve(bookId).enabled, isTrue);
  expect(AiSettingsStore.instance.device.cloudConsent, isFalse);
}

Future<void> _prepare(
  WidgetTester tester, {
  String? bookId,
  Size size = const Size(390, 800),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    if (bookId != null) {
      await AiSettingsStore.instance.clearBookOverride(bookId, 'enabled');
    }
    await tester.binding.setSurfaceSize(null);
  });
}

Widget _app(Widget child) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: true, highContrast: true),
    child: PerformanceScope(
      preferences: const PerformancePreferences(enabled: true),
      explicitReduceMotion: true,
      child: child!,
    ),
  ),
  home: child,
);

ReaderPage _reader(
  String bookId, {
  List<String>? texts,
  TextReplacementStore? replacements,
  TextReplacementEngine? engine,
  MemoryChapterCache? cache,
  ReaderBookmarkStore? bookmarks,
}) {
  final contents = texts ?? [_textA, _textB];
  return ReaderPage(
    bookId: bookId,
    title: 'AI 与阅读导航合并回归',
    chapters: _chapters.take(contents.length).toList(),
    startIndex: 0,
    localOnly: true,
    chapterLoader: (chapter) async => contents[_chapters.indexOf(chapter)],
    readerStore: MemoryReaderStore(),
    readerDevice: _Device(),
    chapterCache: cache ?? MemoryChapterCache(),
    replacementStore: replacements ?? TextReplacementStore(),
    replacementEngine: engine,
    bookmarkStore: bookmarks ?? _Bookmarks(),
  );
}

ReaderPagedView _pager(WidgetTester tester) =>
    tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));
ReaderControls _controls(WidgetTester tester) => tester.widget<ReaderControls>(
  find.byType(ReaderControls, skipOffstage: false),
);

Future<Finder> _openAiPanel(WidgetTester tester) async {
  final onAi = _controls(tester).onAi;
  expect(
    onAi,
    isNotNull,
    reason: 'Current chapter must own an enabled AI view.',
  );
  onAi!();
  await tester.pumpAndSettle();
  final toggle = find.widgetWithText(SwitchListTile, '本次看原文');
  expect(toggle, findsOneWidget);
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  return toggle;
}

Future<void> _closePanel(WidgetTester tester, Finder panelChild) async {
  Navigator.of(tester.element(panelChild)).pop();
  await tester.pumpAndSettle();
}

Future<void> _openMissed(WidgetTester tester) async {
  final paragraph = find
      .byKey(const ValueKey('reader-paragraph-press-0'))
      .hitTestable();
  expect(paragraph, findsOneWidget);
  await tester.longPress(paragraph);
  await tester.pumpAndSettle();
  final menu = tester.widget<ReaderParagraphMenu>(
    find.byType(ReaderParagraphMenu),
  );
  expect(menu.showBookmark, isTrue);
  expect(menu.showAi, isTrue);
  menu.onAction(ReaderParagraphAction.missedChange);
  await tester.pumpAndSettle();
  expect(find.byType(AiMissedSheet), findsOneWidget);
}

void _expectBSnapshot(WidgetTester tester, String bookId) {
  final sheet = tester.widget<AiMissedSheet>(find.byType(AiMissedSheet));
  expect(sheet.bookId, bookId);
  expect(sheet.chapterId, 'b');
  expect(sheet.snapshot.requestText, _snapshotB.requestText);
  expect(sheet.snapshot.requestText, isNot(_snapshotA.requestText));
  expect(sheet.snapshot.canonicalHash, _snapshotB.canonicalHash);
  expect(sheet.snapshot.canonicalHash, isNot(_snapshotA.canonicalHash));
  expect(sheet.sourceStart, 0);
  expect(sheet.sourceEnd, _snapshotB.paragraphs.first.length);
  expect(
    sheet.snapshot.requestText.substring(sheet.sourceStart, sheet.sourceEnd),
    _snapshotB.paragraphs.first,
  );
  // Inspect before saving: no feedback service or application storage is used.
}

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(time: DateTime(2026), battery: 64);
  @override
  Future<void> keepScreenOn(bool on) async {}
  @override
  Future<void> setImmersive(
    bool enabled, {
    bool showStatusBar = false,
    bool showNavigationBar = false,
  }) async {}
  @override
  Future<void> close() async {}
}

class _Bookmarks extends ReaderBookmarkStore {
  final entries = <ReaderBookmark>[];
  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async =>
      entries.where((mark) => mark.bookId == bookId).toList();
  @override
  Future<void> add(ReaderBookmark mark) async {
    entries.removeWhere((entry) => entry.key == mark.key);
    entries.add(mark);
    changes.value++;
  }

  @override
  Future<void> remove(String key) async {
    entries.removeWhere((entry) => entry.key == key);
    changes.value++;
  }
}
