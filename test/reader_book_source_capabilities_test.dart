import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/pages/shuqi_detail_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/widgets/reader/reader_book_panel.dart';
import 'package:fqapp/widgets/reader/reader_classic_chrome.dart';
import 'package:fqapp/widgets/reader/reader_classic_more_sheet.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    http.runWithClient(
      () => ApiClient.instance,
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({'code': 0, 'data': <String, Object>{}}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
  });
  setUp(() {
    setSingleChapterPrefs({
      'reader_page_mode': 'paged',
      'reader_page_turn_style': 'none',
    });
    resetAppUiTestDiagnostics();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (final channel in _channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(channel),
            (call) async => call.method == 'initialize' ? 4000 : null,
          );
    }
  });
  tearDown(() {
    for (final channel in _channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

  for (final localOnly in [false, true]) {
    testWidgets(
      'imported book retains metadata without online loaders or actions, localOnly=$localOnly',
      (tester) async {
        final book = _book('local_123_abcd');
        var detailLoads = 0;
        await _pumpReader(
          tester,
          book: book,
          localOnly: localOnly,
          detailLoader: () async {
            detailLoads++;
            return const BookDetail(title: '不应加载的线上书名');
          },
        );
        await _openControls(tester);
        final toolbar = tester.widget<ReaderClassicToolbar>(
          find.byType(ReaderClassicToolbar),
        );
        expect(toolbar.showCache, isFalse);
        expect(toolbar.showComments, isFalse);
        expect(toolbar.onShare, isNull);
        expect(_key('reader-cache'), findsNothing);
        expect(_key('reader-share'), findsNothing);
        await _openPanel(tester);
        final panel = tester.widget<ReaderBookPanel>(
          find.byType(ReaderBookPanel),
        );
        final detail = await panel.loadDetail();
        expect(detailLoads, 0);
        expect(detail.title, book.title);
        expect(detail.author.name, book.author);
        expect(detail.abstract, book.intro);
        expect(detail.tags, book.categories);
        expect(detail.wordNumber, book.wordNumber);
        expect(panel.onDetails, isNull);
        expect(panel.onAuthor, isNull);
        for (final key in ['reader-book-cover', 'reader-book-title']) {
          expect(tester.widget<InkWell>(_key(key)).onTap, isNull);
        }
        await tester.tap(_key('reader-book-tab-0'));
        await tester.pumpAndSettle();
        expect(find.text(book.intro), findsOneWidget);
        expect(find.text('离线分类'), findsOneWidget);
        Navigator.of(tester.element(find.byType(ReaderBookPanel))).pop();
        await tester.pumpAndSettle();
        await _openMore(tester);
        final more = tester.widget<ReaderClassicMoreSheet>(
          find.byType(ReaderClassicMoreSheet),
        );
        expect(more.canDetails, isFalse);
        expect(more.onAuthor, isNull);
        expect(find.text(book.author), findsOneWidget);
        expect(_key('classic-reader-details'), findsNothing);
        for (final key in ['classic-reader-cover', 'classic-reader-title']) {
          expect(tester.widget<InkWell>(_key(key)).onTap, isNull);
        }
        expect(_key('classic-reader-bookmarks'), findsOneWidget);
        expect(_key('classic-reader-full-search'), findsOneWidget);
        expect(detailLoads, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'Shuqi details receive raw ID and never use Fanqie author route',
    (tester) async {
      final book = _book('7654321', source: 'shuqi');
      await _pumpReader(
        tester,
        book: book,
        readerBookId: 'shuqi:${book.id}',
        localOnly: true,
        detailLoader: () async => const BookDetail(
          author: BookAuthor(id: 'shuqi-author', name: '书旗作者'),
        ),
      );
      await _openPanel(tester);
      final panel = tester.widget<ReaderBookPanel>(
        find.byType(ReaderBookPanel),
      );
      expect(panel.onDetails, isNotNull);
      expect(panel.onAuthor, isNull);
      panel.onDetails!();
      await tester.pumpAndSettle();
      final detailPage = tester.widget<ShuqiDetailPage>(
        find.byType(ShuqiDetailPage),
      );
      expect(detailPage.bookId, book.id);
      expect(detailPage.bookId, isNot(startsWith('shuqi:')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'localOnly Fanqie book keeps supported details and author routes',
    (tester) async {
      var detailLoads = 0;
      await _pumpReader(
        tester,
        book: _book('1234567'),
        localOnly: true,
        detailLoader: () async {
          detailLoads++;
          return const BookDetail(
            author: BookAuthor(id: 'fanqie-author', name: '线上作者'),
          );
        },
      );
      await _openPanel(tester);
      final panel = tester.widget<ReaderBookPanel>(
        find.byType(ReaderBookPanel),
      );
      expect(panel.onDetails, isNotNull);
      expect(panel.onAuthor, isNotNull);
      expect(detailLoads, 1);
      Navigator.of(tester.element(find.byType(ReaderBookPanel))).pop();
      await tester.pumpAndSettle();
      await _openMore(tester);
      final more = tester.widget<ReaderClassicMoreSheet>(
        find.byType(ReaderClassicMoreSheet),
      );
      expect(more.canDetails, isTrue);
      expect(more.onAuthor, isNotNull);
      expect(_key('classic-reader-details'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}

const _channels = [
  'fqapp/system_tts',
  'fqapp/system_tts_events',
  'fqapp/native_player',
];

MediaItem _book(String id, {String source = 'fanqie'}) => MediaItem(
  id: id,
  title: '书籍标题',
  author: '本地保存的作者',
  cover: '',
  badge: '',
  ep: '',
  kind: 'book',
  source: source,
  intro: '保留在本地的书籍简介',
  categories: ['离线分类'],
  wordNumber: 12345,
);

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _pumpReader(
  WidgetTester tester, {
  required MediaItem book,
  required bool localOnly,
  required Future<BookDetail> Function() detailLoader,
  String? readerBookId,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final style = AppThemeStyleStore();
  addTearDown(style.dispose);
  await style.select(AppThemeStyle.classic);
  await tester.pumpWidget(
    AppUiHost(
      store: style,
      home: ReaderPage(
        bookId: readerBookId ?? book.id,
        title: book.title,
        shelfItem: book,
        chapters: [Chapter(itemId: 'chapter-1', title: '第一章', volumeName: '')],
        startIndex: 0,
        localOnly: localOnly,
        bookDetailLoader: detailLoader,
        readerDevice: _Device(),
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        chapterLoader: (_) async => '第一章的正文。',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openControls(WidgetTester tester) async {
  if (_key('reader-classic-toolbar').evaluate().isEmpty) {
    await tester.tapAt(tester.getRect(_key('reader-page-surface')).center);
    await tester.pumpAndSettle();
  }
}

Future<void> _openPanel(WidgetTester tester) async {
  await _openControls(tester);
  await tester.tap(_key('reader-catalogue-entry'));
  await tester.pumpAndSettle();
  expect(find.byType(ReaderBookPanel), findsOneWidget);
}

Future<void> _openMore(WidgetTester tester) async {
  await _openControls(tester);
  await tester.tap(_key('reader-classic-more'));
  await tester.pumpAndSettle();
  expect(find.byType(ReaderClassicMoreSheet), findsOneWidget);
}

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 10, 30, 9),
    battery: 80,
    systemBrightness: .45,
  );
  @override
  Future<bool> setBrightness({
    required bool followSystem,
    required double brightness,
  }) async => true;
  @override
  Future<void> suspend() async {}
  @override
  Future<void> close() async {}
  @override
  Future<ReaderFont?> pickFont() async => null;
}
