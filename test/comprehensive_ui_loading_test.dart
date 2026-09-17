import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';
import 'package:fqapp/widgets/lazy_indexed_stack.dart';
import 'package:hive/hive.dart';

import 'support/fakes.dart';

void main() {
  group('U03 detail download range', () {
    late Directory directory;
    final tempRoot = Directory.systemTemp.absolute;

    setUpAll(() async {
      directory = await tempRoot.createTemp('fqapp-detail-download-');
      Hive.init(directory.path);
      // Open the actual sheet cache before entering the widget fake clock.
      await ChapterCacheStore.instance.cachedChapterIds('book');
    });

    tearDownAll(() async {
      await Hive.close();
      if (directory.absolute.parent.path != tempRoot.path) {
        throw StateError('Temporary directory escaped its parent');
      }
      await directory.delete(recursive: true);
    });

    for (final scenario in <({int chapters, int? resume, int remaining})>[
      (chapters: 1, resume: null, remaining: 1),
      (chapters: 3, resume: null, remaining: 3),
      (chapters: 3, resume: 2, remaining: 1),
    ]) {
      testWidgets('${scenario.chapters} chapters, resume ${scenario.resume}: '
          'current unread chapter is included', (tester) async {
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        final chapters = <Chapter>[
          for (var index = 0; index < scenario.chapters; index++)
            Chapter(
              itemId: 'chapter-$index',
              title: '第${index + 1}章',
              volumeName: '',
            ),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: DetailPage(
              item: MediaItem(
                id: 'book',
                title: '缓存范围测试',
                cover: '',
                author: '',
                badge: '',
                ep: '',
                kind: 'book',
              ),
              detailLoader: (_, {String tab = '小说'}) async => {},
              directoryLoader: (_, {String tab = '小说'}) async => [chapters],
              readerStore: MemoryReaderStore(
                entry: scenario.resume == null
                    ? null
                    : {
                        'id': 'book',
                        'kind': 'book',
                        'chapterId': 'chapter-${scenario.resume}',
                        'episode': scenario.resume,
                      },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载'));
        await tester.pumpAndSettle();
        expect(find.byType(ChapterCacheSheet), findsOneWidget);
        expect(find.text('缓存 ${scenario.remaining} 章'), findsOneWidget);
        expect(find.text('当前已是最后一章'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('U04 hidden kept-alive home stops pagination and resumes once', (
    tester,
  ) async {
    final offsets = <int>[];
    final selected = ValueNotifier(0);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      selected.dispose();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              homepageLoader:
                  ({int tabType = 2, int offset = 0, String? sessionId}) async {
                    if (tabType != 2) {
                      return const HomepagePage(
                        items: [],
                        nextOffset: null,
                        sessionId: null,
                      );
                    }
                    offsets.add(offset);
                    // A valid advancing cursor may accompany a filtered or
                    // duplicate-only page. Bound the fixture so failure cannot
                    // spin through an infinite catalogue in fake time.
                    return HomepagePage(
                      items: const [],
                      nextOffset: offset < 20 ? offset + 1 : null,
                      sessionId: 'session',
                    );
                  },
              searchLoader: (_, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: MaterialApp(
          home: ValueListenableBuilder<int>(
            valueListenable: selected,
            builder: (context, index, child) => LazyIndexedStack(
              index: index,
              children: const [
                HomePage(),
                Scaffold(body: Text('其他页面')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(offsets, [0, 1]);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(offsets, [0, 1, 2]);

    selected.value = 1;
    await tester.pump();
    final beforeHidden = List<int>.of(offsets);
    for (var tick = 0; tick < 4; tick++) {
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    }
    expect(offsets, beforeHidden);

    selected.value = 0;
    await tester.pump();
    await tester.pump();
    expect(offsets, [...beforeHidden, 3]);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(offsets, [...beforeHidden, 3, 4]);
    expect(tester.takeException(), isNull);
  });
}
