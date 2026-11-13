import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/ai_reading/ai_chapter_snapshot.dart';
import 'package:fqapp/services/ai_reading/ai_controller.dart';
import 'package:fqapp/services/ai_reading/ai_settings.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/reader/reader_book_panel.dart';
import 'package:fqapp/widgets/reader/reader_classic_chrome.dart';
import 'package:fqapp/widgets/reader/reader_controls.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

final _chapters = [
  Chapter(itemId: 'a', title: '甲章', volumeName: ''),
  Chapter(itemId: 'b', title: '乙章', volumeName: ''),
];
final _textA = List.generate(20, (i) => '甲章第 $i 段：窗外的风吹过树林。').join('\n');
final _textB = _textA.replaceAll('甲', '乙');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    setSingleChapterPrefs({'reader_page_mode': 'paged'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    // These are real read-only controller compositions. No AI storage,
    // credentials, providers, cloud consent, or generation are initialized.
    expect(AiReadingController.instance.isReady, isFalse);
    expect(AiSettingsStore.instance.device.cloudConsent, isFalse);
  });

  for (final style in [AppThemeStyle.classic, AppThemeStyle.archive]) {
    for (final enabled in [false, true]) {
      testWidgets(
        '${style.name}, AI enabled=$enabled: entries follow the current view',
        (tester) async {
          final classic = style == AppThemeStyle.classic;
          final bookId = 'local:ai-entry-${style.name}-$enabled';
          final store = AppThemeStyleStore();
          final first = Completer<String>();
          final second = Completer<String>();
          final loads = <String>[];
          final controller = AiReadingController.instance;
          await store.select(style);
          await controller.settings.setBookOverride(bookId, 'enabled', enabled);
          expect(controller.configFor(bookId).aiRequestEnabled, enabled);
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            // Complete any pending local prefetch after disposing the reader.
            if (!first.isCompleted) first.complete(_textA);
            if (!second.isCompleted) second.complete(_textB);
            await tester.pumpAndSettle();
            await tester.pump(const Duration(seconds: 4));
            await controller.settings.clearBookOverride(bookId, 'enabled');
            store.dispose();
            await tester.binding.setSurfaceSize(null);
          });

          await tester.pumpWidget(
            AppUiHost(
              store: store,
              home: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: true, highContrast: true),
                  child: PerformanceScope(
                    preferences: const PerformancePreferences(enabled: true),
                    explicitReduceMotion: true,
                    child: ReaderPage(
                      bookId: bookId,
                      title: 'AI 入口策略',
                      chapters: _chapters,
                      startIndex: 0,
                      localOnly: true,
                      chapterLoader: (chapter) {
                        loads.add(chapter.itemId);
                        return chapter.itemId == 'a'
                            ? first.future
                            : second.future;
                      },
                      readerStore: MemoryReaderStore(),
                      readerDevice: _Device(),
                      chapterCache: MemoryChapterCache(),
                      replacementStore: TextReplacementStore(),
                      bookmarkStore: _Bookmarks(),
                    ),
                  ),
                ),
              ),
            ),
          );
          await _pumpLoading(tester);
          expect(loads, contains('a'));
          _expectEntry(tester, classic: classic, visible: false);
          if (classic) {
            await _expectBookPanel(tester, visible: false);
          }

          first.complete(_textA);
          await tester.pumpAndSettle();
          _expectCurrentComposition(tester, controller, bookId, 0, _textA);
          _expectEntry(tester, classic: classic, visible: classic || enabled);
          if (classic) {
            await _expectBookPanel(tester, visible: true, enabled: enabled);
          }
          if (classic || enabled) {
            await _openControls(tester);
            await tester.tap(find.byKey(const ValueKey('reader-ai')));
            await tester.pumpAndSettle();
            _expectAiSheet(enabled);
            await _closeAiSheet(tester);
          }

          // A valid view for A must not leave an entry behind while B loads.
          final next = classic
              ? tester
                    .widget<ReaderClassicControls>(
                      find.byType(ReaderClassicControls, skipOffstage: false),
                    )
                    .onNext
              : tester
                    .widget<ReaderControls>(
                      find.byType(ReaderControls, skipOffstage: false),
                    )
                    .onNext;
          expect(next, isNotNull);
          next!();
          await _pumpLoading(tester);
          expect(loads, contains('b'));
          _expectEntry(tester, classic: classic, visible: false);
          if (classic) {
            await _expectBookPanel(tester, visible: false);
          }

          second.complete(_textB);
          await tester.pumpAndSettle();
          _expectCurrentComposition(tester, controller, bookId, 1, _textB);
          _expectEntry(tester, classic: classic, visible: classic || enabled);
          if (classic) {
            await _expectBookPanel(tester, visible: true, enabled: enabled);
          }
          expect(controller.settings.resolve(bookId).enabled, enabled);
          expect(controller.settings.device.cloudConsent, isFalse);
          expect(controller.isReady, isFalse);
          expect(controller.statusFor(bookId, 'a').running, isFalse);
          expect(controller.statusFor(bookId, 'b').running, isFalse);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

void _expectEntry(
  WidgetTester tester, {
  required bool classic,
  required bool visible,
}) {
  final onAi = classic
      ? tester
            .widget<ReaderClassicControls>(
              find.byType(ReaderClassicControls, skipOffstage: false),
            )
            .onAi
      : tester
            .widget<ReaderControls>(
              find.byType(ReaderControls, skipOffstage: false),
            )
            .onAi;
  expect(onAi, visible ? isNotNull : isNull);
  expect(
    find.byKey(const ValueKey('reader-ai'), skipOffstage: false),
    visible ? findsOneWidget : findsNothing,
  );
}

void _expectCurrentComposition(
  WidgetTester tester,
  AiReadingController controller,
  String bookId,
  int index,
  String text,
) {
  final pager = tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));
  expect(pager.layout.blocks[1].text, contains(index == 0 ? '甲章' : '乙章'));
  final snapshot = AiChapterSnapshotBuilder.fromContent(
    ChapterContent.fromPlainText(text, illustrationsChecked: true),
    _chapters[index].title,
  );
  expect(
    controller.knownDisplayRevision(
      bookId,
      _chapters[index].itemId,
      snapshot.canonicalHash,
    ),
    isNotNull,
    reason: 'The real controller must compose the currently loaded chapter.',
  );
}

Future<void> _expectBookPanel(
  WidgetTester tester, {
  required bool visible,
  bool? enabled,
}) async {
  final controls = tester.widget<ReaderClassicControls>(
    find.byType(ReaderClassicControls, skipOffstage: false),
  );
  controls.onDirectory();
  await _pumpLoading(tester);
  final panel = tester.widget<ReaderBookPanel>(find.byType(ReaderBookPanel));
  expect(panel.onAi, visible ? isNotNull : isNull);
  expect(panel.aiLabel, 'AI 校对');
  final entry = find.byKey(const ValueKey('reader-book-ai'));
  expect(entry, visible ? findsOneWidget : findsNothing);
  if (visible) {
    expect(entry.hitTestable(), findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderBookPanel), findsNothing);
    _expectAiSheet(enabled!);
    await _closeAiSheet(tester);
  } else {
    Navigator.of(tester.element(find.byType(ReaderBookPanel))).pop();
    await _pumpLoading(tester);
  }
}

void _expectAiSheet(bool enabled) {
  expect(find.widgetWithText(SwitchListTile, '本次看原文'), findsOneWidget);
  expect(find.text(enabled ? '需要同意云端正文传输' : 'AI 阅读优化已关闭'), findsOneWidget);
}

Future<void> _closeAiSheet(WidgetTester tester) async {
  Navigator.of(
    tester.element(find.widgetWithText(SwitchListTile, '本次看原文')),
  ).pop();
  await tester.pumpAndSettle();
}

Future<void> _openControls(WidgetTester tester) async {
  final toolbar = find.byKey(const ValueKey('reader-classic-toolbar'));
  final archiveToolbar = find.byKey(const ValueKey('reader-toolbar'));
  if (toolbar.evaluate().isNotEmpty || archiveToolbar.evaluate().isNotEmpty) {
    return;
  }
  await tester.tapAt(
    tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
  );
  await tester.pumpAndSettle();
}

// A held chapter loader leaves an indeterminate progress indicator animating;
// fixed frame advances let routes finish without waiting for it to settle.
Future<void> _pumpLoading(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
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
  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async => [];
}
