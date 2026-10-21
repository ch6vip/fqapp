import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/comic_reader_page.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';

import 'support/fakes.dart';

void main() {
  for (final savedKind in ['video', 'manju']) {
    testWidgets(
      'manju detail resumes $savedKind history through the video API',
      (tester) async {
        final observer = _RouteObserver();
        final requests = <String>[];
        final store = MemoryReaderStore(
          entry: {
            'id': 'series',
            'kind': savedKind,
            'episodeId': 'second',
            'episode': 0,
            'position': 37.0,
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: DetailPage(
              item: MediaItem(
                id: 'episode',
                seriesId: 'series',
                title: '测试漫剧',
                cover: '',
                author: '',
                badge: '',
                ep: '2',
                kind: 'manju',
              ),
              readerStore: store,
              detailLoader: (id, {String tab = '小说'}) async {
                requests.add('$tab:$id');
                return {};
              },
              directoryLoader: (id, {String tab = '小说'}) async {
                requests.add('$tab:$id');
                return [_chapters];
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(requests, ['短剧:series', '短剧:series']);
        expect(find.text('继续观看'), findsOneWidget);
        final context = tester.element(find.byType(DetailPage));
        await tester.tap(find.byKey(const Key('detail_read_button')));
        await tester.idle();
        final page =
            (observer.lastRoute! as MaterialPageRoute).builder(context)
                as PlayerPage;
        expect(page.kind, 'manju');
        expect(page.bookId, 'series');
        expect(page.startIndex, 1);
        expect(page.historyStore, same(store));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('a long directory error can be scrolled to retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          // 目录失败时会去查本地整本缓存；注入空缓存，让这条路径不碰真实存储。
          chapterCache: MemoryChapterCache(),
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async {
            if (++attempts == 1) {
              throw StateError(List.filled(60, '目录请求失败，连接中断。').join('\n'));
            }
            return [_chapters];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试').hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsOneWidget);
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting a chapter supersedes a pending continue action', (
    tester,
  ) async {
    final store = _PendingHistory();
    final observer = _RouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: DetailPage(
          item: _book,
          readerStore: store,
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _revealSecondChapter(tester);
    await tester.tap(find.byKey(const Key('detail_read_button')));
    await tester.tap(find.text('第二章'));
    expect(observer.pushes, 2);
    store.pending.complete({'chapterId': 'first', 'episode': 0});
    await tester.idle();
    expect(observer.pushes, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed directory stays retryable when metadata succeeds', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          // 目录失败时会去查本地整本缓存；注入空缓存，让这条路径不碰真实存储。
          chapterCache: MemoryChapterCache(),
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async {
            if (++attempts == 1) throw StateError('directory unavailable');
            return [_chapters];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('暂无目录'), findsNothing);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsOneWidget);
    expect(find.byKey(const Key('detail_read_button')), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('目录失败但本地有整本缓存时，给出「从缓存阅读」入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = MemoryChapterCache();
    await cache.saveBook(
      CachedBook(id: 'book', title: '测试书', chapters: _chapters),
    );
    await cache.write(
      bookId: 'book',
      chapterId: 'first',
      title: '第一章',
      text: '离线正文',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          chapterCache: cache,
          readerStore: MemoryReaderStore(),
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async =>
              throw StateError('directory unavailable'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('从缓存阅读'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('detail_read_cached')));
    await tester.tap(find.byKey(const Key('detail_read_cached')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage, skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('整本下载跳过已缓存章节，从第一个缺口继续（issue #108）', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final cache = MemoryChapterCache();
    // 「缓存到一半被网络中断」：前 2 章已在磁盘上，剩下 2 章没下。
    final chapters = [
      for (var i = 0; i < 4; i++)
        Chapter(itemId: 'c$i', title: '第$i章', volumeName: ''),
    ];
    for (var i = 0; i < 2; i++) {
      await cache.write(
        bookId: 'book',
        chapterId: 'c$i',
        title: '第$i章',
        text: ChapterContent.fromPlainText(
          '已缓存的正文$i',
          illustrationsChecked: true,
        ).toCacheText(),
      );
    }
    final fetched = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          chapterCache: cache,
          readerStore: MemoryReaderStore(),
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async => [chapters],
          chapterLoader: (chapter) async {
            fetched.add(chapter.itemId);
            // 让批次停在第一章，好在它进行时读进度文案。
            await Future<void>.delayed(const Duration(milliseconds: 40));
            return ChapterContent.fromPlainText(
              '下载的正文${chapter.itemId}',
              illustrationsChecked: true,
            ).toCacheText();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('下载'));
    await tester.tap(find.text('下载'));
    // 用 pump 而不是 settle：要在批次进行时读到总量。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    // 修复前批次总量是「从续读位置到末章」的 4 章（重新缓存一遍已缓存的
    // c0、c1）；修复后从第一个缺口开始，总量只剩 2 章。
    expect(
      find.textContaining('/2'),
      findsOneWidget,
      reason: '批次总量应为缺失的 2 章，而不是全部 4 章',
    );
    await tester.pumpAndSettle();

    // ChapterDownload 自身也会逐章跳过已缓存正文，因此实际抓取的只有缺口。
    expect(fetched, ['c2', 'c3']);
    expect(await cache.cachedChapterIds('book'), {'c0', 'c1', 'c2', 'c3'});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('目录失败且本地没有缓存时，只留重试', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          chapterCache: MemoryChapterCache(),
          readerStore: MemoryReaderStore(),
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async =>
              throw StateError('directory unavailable'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('从缓存阅读'), findsNothing);
  });

  testWidgets('离线时目录还没回来就先给出「从缓存阅读」', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final cache = MemoryChapterCache();
    await cache.saveBook(
      CachedBook(id: 'book', title: '测试书', chapters: _chapters),
    );
    await cache.write(
      bookId: 'book',
      chapterId: 'first',
      title: '第一章',
      text: '离线正文',
    );
    // 目录请求悬着不返回：弱网下页面停在 loading，错误卡片根本不会出现。
    final pending = Completer<List<List<Chapter>>>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(const []);
    });
    final observer = _RouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: DetailPage(
          item: _book,
          chapterCache: cache,
          readerStore: MemoryReaderStore(),
          connectivity: () async => (online: false, metered: false),
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) => pending.future,
        ),
      ),
    );
    // loading 期间 spinner 一直在动，pumpAndSettle 会超时，只能手动 pump。
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.text('正在加载书籍与目录'), findsOneWidget);
    expect(find.text('从缓存阅读'), findsOneWidget);
    await tester.tap(find.byKey(const Key('detail_read_cached')));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final context = tester.element(find.byType(DetailPage));
    expect(
      (observer.lastRoute! as MaterialPageRoute).builder(context),
      isA<ReaderPage>(),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('optional metadata failure keeps a usable directory visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          detailLoader: (id, {String tab = '小说'}) async =>
              throw StateError('missing metadata'),
          directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsOneWidget);
    expect(find.byKey(const Key('detail_read_button')), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('continue follows the saved chapter ID after directory reorder', (
    tester,
  ) async {
    final observer = _RouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: DetailPage(
          item: _book,
          readerStore: MemoryReaderStore(
            entry: {'id': 'book', 'chapterId': 'second', 'episode': 0},
          ),
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(DetailPage));
    await tester.tap(find.byKey(const Key('detail_read_button')));
    final page = (observer.lastRoute! as MaterialPageRoute).builder(context);
    expect(page, isA<ReaderPage>());
    expect((page as ReaderPage).startIndex, 1);
    // Inspect the navigation result before mounting the network-backed reader.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a book resumes listening from the audio-scoped record', (
    tester,
  ) async {
    final observer = _RouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: DetailPage(
          item: _book,
          readerStore: MemoryReaderStore(
            entry: {
              'id': 'audio:book',
              'kind': 'audio',
              'chapterId': 'second',
              'episode': 0,
              'position': 240.0,
            },
          ),
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(DetailPage));
    await tester.tap(find.byKey(const Key('detail_action_听书')));
    await tester.idle();
    final page = (observer.lastRoute! as MaterialPageRoute).builder(context);
    expect(page, isA<AudioPage>());
    expect((page as AudioPage).startIndex, 1);
    // Inspect the navigation result before mounting the audio player.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final media in [
    (kind: 'audio', tab: '听书', action: '开始收听'),
    (kind: 'manga', tab: '漫画', action: '开始阅读'),
  ]) {
    testWidgets(
      '${media.kind} opens its native page with the selected chapter',
      (tester) async {
        final observer = _RouteObserver();
        final tabs = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: DetailPage(
              item: _item(media.kind),
              detailLoader: (id, {String tab = '小说'}) async {
                tabs.add(tab);
                throw StateError('optional metadata unavailable');
              },
              directoryLoader: (id, {String tab = '小说'}) async {
                tabs.add(tab);
                return [_chapters];
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tabs, [media.tab, media.tab]);
        expect(find.text(media.action), findsOneWidget);
        final context = tester.element(find.byType(DetailPage));
        await _revealSecondChapter(tester);
        await tester.tap(find.text('第二章'));
        final page = (observer.lastRoute! as MaterialPageRoute).builder(
          context,
        );
        if (media.kind == 'audio') {
          expect(page, isA<AudioPage>());
          expect((page as AudioPage).startIndex, 1);
          expect(page.bookId, 'book');
        } else {
          expect(page, isA<ComicReaderPage>());
          expect((page as ComicReaderPage).startIndex, 1);
          expect(page.bookId, 'book');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    for (final savedKind in [media.kind, 'book']) {
      testWidgets(
        '${media.kind} checks the saved $savedKind kind before resuming',
        (tester) async {
          final observer = _RouteObserver();
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [observer],
              home: DetailPage(
                item: _item(media.kind),
                readerStore: MemoryReaderStore(
                  entry: {
                    'id': 'book',
                    'kind': savedKind,
                    'chapterId': 'second',
                    'episode': 0,
                    'position': 240.0,
                  },
                ),
                detailLoader: (id, {String tab = '小说'}) async => {},
                directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
              ),
            ),
          );
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(DetailPage));
          await tester.tap(find.byKey(const Key('detail_read_button')));
          await tester.idle();
          final page = (observer.lastRoute! as MaterialPageRoute).builder(
            context,
          );
          final index = switch (page) {
            AudioPage() => page.startIndex,
            ComicReaderPage() => page.startIndex,
            _ => -1,
          };
          expect(index, savedKind == media.kind ? 1 : 0);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      '${media.kind} ignores a resume read after explicit selection',
      (tester) async {
        final store = _PendingHistory();
        final observer = _RouteObserver();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: DetailPage(
              item: _item(media.kind),
              readerStore: store,
              detailLoader: (id, {String tab = '小说'}) async => {},
              directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _revealSecondChapter(tester);
        await tester.tap(find.byKey(const Key('detail_read_button')));
        await tester.tap(find.text('第二章'));
        expect(observer.pushes, 2);
        store.pending.complete({'kind': media.kind, 'chapterId': 'first'});
        await tester.idle();
        expect(observer.pushes, 2);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('the download action caches the whole book without a sheet', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final cache = MemoryChapterCache(chapterCapacity: 1);
    final fetched = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
          readerStore: MemoryReaderStore(),
          chapterCache: cache,
          chapterLoader: (chapter) async {
            fetched.add(chapter.itemId);
            return ChapterContent.fromPlainText(
              '正文${chapter.itemId}',
              illustrationsChecked: true,
            ).toCacheText();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(fetched, ['first', 'second']);
    expect(await cache.cachedChapterIds('book'), {'first', 'second'});
    // A download is pinned: the cache's one-chapter automatic budget neither
    // truncates nor evicts it.
    expect(cache.pinned['book'], {'first', 'second'});
    expect(find.textContaining('缓存完成'), findsOneWidget);
    // The action goes back to its idle label once the batch ends.
    expect(find.text('下载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a running download stops it', (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final cache = MemoryChapterCache();
    final pending = Completer<String>();
    final fetched = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
          readerStore: MemoryReaderStore(),
          chapterCache: cache,
          chapterLoader: (chapter) {
            fetched.add(chapter.itemId);
            return pending.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载'));
    await tester.pump();
    // Progress replaces the static icon while the batch runs.
    expect(find.text('缓存 0/2'), findsOneWidget);
    await tester.tap(find.text('缓存 0/2'));
    await tester.pump();
    pending.complete('不应在停止后保存的正文');
    await tester.pumpAndSettle();
    expect(await cache.cachedChapterIds('book'), isEmpty);
    expect(find.textContaining('已停止缓存'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('autoOpenReader opens the reader directly for books', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final observer = _RouteObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: DetailPage(
          item: _book,
          autoOpenReader: true,
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
          readerStore: MemoryReaderStore(),
          // The auto-opened reader mounts for real: a memory cache keeps
          // its chapter load off Hive (uninitialized in tests).
          chapterCache: MemoryChapterCache(),
        ),
      ),
    );
    // Flush the detail load + the auto-open replacement. Each pump advances
    // the fake clock so the replacement route's transition finishes; the
    // reader's own chapter load fails into its error view (live API here).
    for (
      var i = 0;
      i < 20 && find.byType(DetailPage).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.idle();
    }
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.byType(DetailPage), findsNothing);
    final context = tester.element(find.byType(ReaderPage));
    final page =
        (observer.lastRoute! as MaterialPageRoute).builder(context)
            as ReaderPage;
    expect(page.bookId, 'book');
    expect(page.startIndex, 0);
    expect(page.chapters.length, 2);
  });

  testWidgets('autoOpenReader stays on detail for audio and empty catalogues', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _item('audio'),
          autoOpenReader: true,
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async => [_chapters],
          readerStore: MemoryReaderStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    expect(find.byType(AudioPage), findsNothing);
    expect(find.byType(ReaderPage), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          autoOpenReader: true,
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) async =>
              const <List<Chapter>>[],
          readerStore: MemoryReaderStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    expect(find.byType(ReaderPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

final _book = MediaItem(
  id: 'book',
  title: '测试书',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);
final _chapters = <Chapter>[
  Chapter(itemId: 'first', title: '第一章', volumeName: ''),
  Chapter(itemId: 'second', title: '第二章', volumeName: ''),
];

MediaItem _item(String kind) => MediaItem(
  id: 'book',
  title: '测试作品',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: kind,
);

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? lastRoute;
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    lastRoute = route;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    // pushReplacement (direct reader) swaps the route without a push.
    if (newRoute != null) lastRoute = newRoute;
  }
}

class _PendingHistory extends MemoryReaderStore {
  final pending = Completer<Map<String, dynamic>?>();

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) => pending.future;
}

Future<void> _revealSecondChapter(WidgetTester tester) async {
  await tester.ensureVisible(
    find.byKey(const Key('detail_preview_chapter_second')),
  );
  await tester.pumpAndSettle();
}
