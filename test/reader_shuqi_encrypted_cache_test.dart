import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_full_search.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/reader/reader_full_search_panel.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

const _shuqiId = 'shuqi:42';
const _fanqieId = '42';
const _title = '书旗完整目录';
const _cover = 'shuqi-cover-token';
final _chapters = [
  for (var i = 0; i < 8; i++)
    Chapter(
      itemId: '$i',
      title: '第$i章',
      volumeName: '卷${i ~/ 4}',
      version: 'shuqi-v$i',
    ),
];

String _body(String id) => 'needle SHUQI-ENCRYPTED-BODY-$id';
String _cacheText(String text) => ChapterContent.fromPlainText(
  text,
  illustrationsChecked: true,
).toCacheText();
Map<String, int> _callCounts(List<String> calls) => {
  for (final id in calls.toSet())
    id: calls.where((called) => called == id).length,
};

/// Let Hive's actual file IO complete between fake-clock reader frames.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() complete, {
  required String reason,
}) async {
  for (var i = 0; i < 400 && !complete(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
  expect(complete(), isTrue, reason: reason);
}

Future<ReaderFullSearchPanel> _mountSearch(
  WidgetTester tester, {
  required ChapterCacheStore cache,
  required ChapterTextLoader loader,
}) async {
  setSingleChapterPrefs({'reader_page_mode': 'scroll'});
  final style = AppThemeStyleStore();
  await style.select(AppThemeStyle.classic);
  addTearDown(() async {
    await _unmount(tester);
    style.dispose();
  });
  await tester.pumpWidget(
    AppUiHost(
      store: style,
      home: ReaderPage(
        bookId: _shuqiId,
        title: _title,
        cover: _cover,
        chapters: _chapters,
        startIndex: 0,
        localOnly: true,
        chapterLoader: loader,
        chapterCache: cache,
        readerStore: MemoryReaderStore(),
        readerDevice: _Device(),
        replacementStore: TextReplacementStore(),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () => find
        .textContaining(_body('0'), findRichText: true)
        .evaluate()
        .isNotEmpty,
    reason: 'The real reader must finish loading the first encrypted chapter',
  );
  await tester.pumpAndSettle();
  await tester.tapAt(
    tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('reader-classic-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('classic-reader-full-search')));
  await tester.pumpAndSettle();
  return tester.widget<ReaderFullSearchPanel>(
    find.byType(ReaderFullSearchPanel),
  );
}

ReaderFullSearchController _controller(ReaderFullSearchPanel panel) {
  final clock = TestWidgetsFlutterBinding.instance.clock;
  final started = clock.now();
  final controller = ReaderFullSearchController(
    chapters: panel.chapters,
    loadChapter: panel.loadChapter,
    loadChapterForSearch: panel.loadChapterForSearch,
    networkElapsed: () => clock.now().difference(started),
  );
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _search(
  WidgetTester tester,
  ReaderFullSearchController controller,
  String query,
) async {
  var finished = false;
  final task = controller.search(query).then((_) => finished = true);
  await _pumpUntil(
    tester,
    () => finished,
    reason: 'Eight chapters must finish searching through the real Hive cache',
  );
  await task;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void _expectCatalogue(CachedBook? book) {
  expect(book, isNotNull);
  expect(book!.id, _shuqiId);
  expect(book.title, _title);
  expect(book.cover, _cover);
  expect(book.chapters.map((c) => c.itemId), _chapters.map((c) => c.itemId));
  expect(book.chapters.map((c) => c.title), _chapters.map((c) => c.title));
  expect(
    book.chapters.map((c) => c.volumeName),
    _chapters.map((c) => c.volumeName),
  );
  expect(book.chapters.map((c) => c.version), _chapters.map((c) => c.version));
}

void main() {
  late Directory directory;
  late InMemorySecureKeyStorage storage;
  late SecureKeyProvider keys;
  late ChapterCacheStore store;
  late Zone ioZone;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'reader-shuqi-encrypted-',
    );
    Hive.init(directory.path);
    storage = InMemorySecureKeyStorage();
    keys = SecureKeyProvider(storage: storage);
    ioZone = Zone.current;
    store = _RealIoChapterCacheStore(ioZone, keys);
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'Shuqi reader persists eight encrypted chapters and reopens offline with isolated metadata',
    (tester) async {
      const foreignBody = 'FANQIE-ONLY-BODY';
      final foreignBook = CachedBook(
        id: _fanqieId,
        title: '番茄独立目录',
        cover: 'fanqie-cover-token',
        chapters: [
          Chapter(
            itemId: '4',
            title: '番茄第四章',
            volumeName: '番茄卷',
            version: 'fanqie-v4',
          ),
        ],
      );
      await tester.runAsync(() async {
        await store.saveBook(foreignBook);
        await store.write(
          bookId: _fanqieId,
          chapterId: '4',
          title: foreignBook.chapters.single.title,
          text: _cacheText(foreignBody),
          pinned: true,
        );
      });
      final calls = <String>[];
      final panel = await _mountSearch(
        tester,
        cache: store,
        loader: (chapter) async {
          calls.add(chapter.itemId);
          return _body(chapter.itemId);
        },
      );
      final controller = _controller(panel);
      await _search(tester, controller, 'needle');
      expect(controller.state.matchCount, 8);
      expect(controller.state.failedChapters, isEmpty);
      expect(
        _callCounts(calls),
        {for (final c in _chapters) c.itemId: 1},
        reason:
            'Foreground loading and adjacent prefetch must not duplicate search requests',
      );
      await _search(tester, controller, 'SHUQI-ENCRYPTED-BODY');
      expect(controller.state.matchCount, 8);
      expect(
        _callCounts(calls),
        {for (final c in _chapters) c.itemId: 1},
        reason: 'The five-entry memory cache must fall back to encrypted disk',
      );
      await tester.runAsync(() async {
        expect(await store.cachedChapterIds(_shuqiId), {
          for (final c in _chapters) c.itemId,
        });
        _expectCatalogue(await store.savedCatalogue(_shuqiId));
        _expectCatalogue(await store.cachedBook(_shuqiId));
        expect((await store.stats(bookId: _shuqiId)).chapterCount, 8);
        expect((await store.stats(bookId: _fanqieId)).chapterCount, 1);
        expect(
          (await store.savedCatalogue(_fanqieId))!.toMap(),
          foreignBook.toMap(),
        );
        expect(
          await store.read(bookId: _fanqieId, chapterId: '4'),
          _cacheText(foreignBody),
        );
        expect(
          await store.read(bookId: _shuqiId, chapterId: '4'),
          _cacheText(_body('4')),
        );
      });
      await _unmount(tester);
      await tester.runAsync(() async {
        await Hive.close();
        expect(await Hive.boxExists('chapter_cache_v1'), isFalse);
        expect(await Hive.boxExists('chapter_cache_catalog_v1'), isFalse);
        expect(
          await Hive.boxExists(
            EncryptedHive.encryptedBoxName('chapter_cache_v1'),
          ),
          isTrue,
        );
        expect(
          await Hive.boxExists(
            EncryptedHive.encryptedBoxName('chapter_cache_catalog_v1'),
          ),
          isTrue,
        );
        final files = directory.listSync().whereType<File>().where((file) {
          final name = file.uri.pathSegments.last;
          return name.startsWith('chapter_cache_') && name.endsWith('.hive');
        }).toList();
        expect(files, hasLength(2));
        for (final file in files) {
          final bytes = String.fromCharCodes(file.readAsBytesSync());
          for (final chapter in _chapters) {
            expect(
              bytes,
              isNot(contains(_body(chapter.itemId))),
              reason: 'Chapter plaintext leaked into ${file.path}',
            );
          }
          expect(
            bytes,
            isNot(contains(_cover)),
            reason: 'Source catalogue metadata leaked into ${file.path}',
          );
          expect(bytes, isNot(contains(foreignBody)));
        }
      });

      // A fresh provider reloads the same persisted keys, and a fresh ReaderPage
      // has no in-memory chapter texts or coalesced requests from the first run.
      final reopened = ioZone.run(
        () => _RealIoChapterCacheStore(
          ioZone,
          SecureKeyProvider(storage: storage),
        ),
      );
      final offlineCalls = <String>[];
      final reopenedPanel = await _mountSearch(
        tester,
        cache: reopened,
        loader: (chapter) async {
          offlineCalls.add(chapter.itemId);
          throw StateError('Network is offline');
        },
      );
      final reopenedController = _controller(reopenedPanel);
      for (final query in ['needle', 'SHUQI-ENCRYPTED-BODY']) {
        await _search(tester, reopenedController, query);
        expect(reopenedController.state.matchCount, 8);
        expect(reopenedController.state.failedChapters, isEmpty);
        expect(offlineCalls, isEmpty);
      }
      await tester.runAsync(() async {
        _expectCatalogue(await reopened.savedCatalogue(_shuqiId));
        _expectCatalogue(await reopened.cachedBook(_shuqiId));
        expect(
          (await reopened.savedCatalogue(_fanqieId))!.toMap(),
          foreignBook.toMap(),
        );
        expect(await reopened.cachedChapterIds(_fanqieId), {'4'});
        expect(
          await reopened.read(bookId: _fanqieId, chapterId: '4'),
          _cacheText(foreignBody),
        );
      });
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets(
    'failed Shuqi chapter retries once and then survives offline reopen',
    (tester) async {
      final calls = <String>[];
      var failChapter = true;
      final panel = await _mountSearch(
        tester,
        cache: store,
        loader: (chapter) async {
          calls.add(chapter.itemId);
          if (chapter.itemId == '4' && failChapter) {
            throw StateError('Temporary Shuqi download failure');
          }
          return _body(chapter.itemId);
        },
      );
      final controller = _controller(panel);
      await _search(tester, controller, 'needle');
      expect(controller.state.matchCount, 7);
      expect(controller.state.failedChapters.map((c) => c.itemId), ['4']);
      expect(_callCounts(calls), {for (final c in _chapters) c.itemId: 1});
      await tester.runAsync(() async {
        expect(await store.cachedChapterIds(_shuqiId), {
          for (final c in _chapters)
            if (c.itemId != '4') c.itemId,
        });
        expect(await store.read(bookId: _shuqiId, chapterId: '4'), isNull);
        _expectCatalogue(await store.savedCatalogue(_shuqiId));
      });

      failChapter = false;
      await _search(tester, controller, 'needle');
      expect(controller.state.matchCount, 8);
      expect(controller.state.failedChapters, isEmpty);
      expect(_callCounts(calls), {
        for (final c in _chapters) c.itemId: c.itemId == '4' ? 2 : 1,
      });
      await _search(tester, controller, 'SHUQI-ENCRYPTED-BODY');
      expect(controller.state.matchCount, 8);
      expect(_callCounts(calls), {
        for (final c in _chapters) c.itemId: c.itemId == '4' ? 2 : 1,
      });
      await _unmount(tester);
      await tester.runAsync(() async {
        await Hive.close();
        final reopened = ChapterCacheStore(
          keys: SecureKeyProvider(storage: storage),
        );
        expect(await reopened.cachedChapterIds(_shuqiId), {
          for (final c in _chapters) c.itemId,
        });
        expect(
          await reopened.read(bookId: _shuqiId, chapterId: '4'),
          _cacheText(_body('4')),
        );
        _expectCatalogue(await reopened.savedCatalogue(_shuqiId));
      });
      expect(tester.takeException(), isNull);
    },
  );
}

/// Execute the real store's entire write/flush queue outside fake async.
/// Merely yielding IO between frames leaves Hive's deferred flush on the fake
/// clock, which makes closing and reopening a cache deadlock in runAsync.
class _RealIoChapterCacheStore extends ChapterCacheStore {
  _RealIoChapterCacheStore(this.ioZone, SecureKeyProvider keys)
    : super(keys: keys);

  final Zone ioZone;

  @override
  Future<String?> read({required String bookId, required String chapterId}) =>
      ioZone.run(() => super.read(bookId: bookId, chapterId: chapterId));

  @override
  Future<void> saveBook(CachedBook book) =>
      ioZone.run(() => super.saveBook(book));

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) => ioZone.run(
    () => super.write(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
      pinned: pinned,
    ),
  );
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
