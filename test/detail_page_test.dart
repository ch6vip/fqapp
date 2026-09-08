import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/comic_reader_page.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/reader_page.dart';

import 'support/fakes.dart';

void main() {
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
    await tester.tap(find.text('阅读 / 续读'));
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
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('阅读 / 续读'), findsOneWidget);
    expect(attempts, 2);
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
    expect(find.text('阅读 / 续读'), findsOneWidget);
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
    await tester.tap(find.text('阅读 / 续读'));
    final page = (observer.lastRoute! as MaterialPageRoute).builder(context);
    expect(page, isA<ReaderPage>());
    expect((page as ReaderPage).startIndex, 1);
    // Inspect the navigation result before mounting the network-backed reader.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final media in [
    (kind: 'audio', tab: '听书', action: '播放 / 续听'),
    (kind: 'manga', tab: '漫画', action: '阅读 / 续读'),
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
          await tester.tap(find.text(media.action));
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
        await tester.tap(find.text(media.action));
        await tester.tap(find.text('第二章'));
        expect(observer.pushes, 2);
        store.pending.complete({'kind': media.kind, 'chapterId': 'first'});
        await tester.idle();
        expect(observer.pushes, 2);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
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
}

class _PendingHistory extends MemoryReaderStore {
  final pending = Completer<Map<String, dynamic>?>();

  @override
  Future<Map<String, dynamic>?> historyEntry(String id) => pending.future;
}
