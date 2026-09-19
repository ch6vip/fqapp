import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/widgets/chapter_cache_sheet.dart';
import 'package:fqapp/widgets/lazy_indexed_stack.dart';

import 'support/fakes.dart';

void main() {
  group('U03 detail download', () {
    for (final scenario in <({int chapters, int? resume})>[
      (chapters: 1, resume: null),
      (chapters: 3, resume: null),
      (chapters: 3, resume: 2),
    ]) {
      testWidgets('${scenario.chapters} chapters, resume ${scenario.resume}: '
          'one tap caches the rest of the catalogue', (tester) async {
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        final chapters = <Chapter>[
          for (var index = 0; index < scenario.chapters; index++)
            Chapter(
              itemId: 'chapter-$index',
              title: '第${index + 1}章',
              volumeName: '',
            ),
        ];
        final cache = MemoryChapterCache();
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
              chapterCache: cache,
              chapterLoader: (chapter) async => ChapterContent.fromPlainText(
                '正文${chapter.itemId}',
                illustrationsChecked: true,
              ).toCacheText(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载'));
        await tester.pumpAndSettle();
        // The detail page downloads: no sheet, no range to choose.
        expect(find.byType(ChapterCacheSheet), findsNothing);
        final start = scenario.resume ?? 0;
        expect(await cache.cachedChapterIds('book'), {
          for (var index = start; index < scenario.chapters; index++)
            'chapter-$index',
        });
        expect(find.textContaining('缓存完成'), findsOneWidget);
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
