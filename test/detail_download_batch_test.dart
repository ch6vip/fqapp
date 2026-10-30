import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/widgets/detail/detail_read_bar.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('整本下载跳过已缓存章节，从第一个缺口继续（issue #108）', (tester) async {
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

    await tester.tap(find.byKey(const Key('detail_action_下载')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail_download_all')));
    // 用 pump 而不是 settle：要在批次进行时读到总量。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    // 修复前批次总量是「从续读位置到末章」的 4 章（重新缓存一遍已缓存的
    // c0、c1）；修复后从第一个缺口开始，总量只剩 2 章。
    final bar = tester.widget<DetailReadBar>(find.byType(DetailReadBar));
    expect(bar.download?.total, 2, reason: '批次总量应为缺失的 2 章，而不是全部 4 章');
    await tester.pumpAndSettle();

    // ChapterDownload 自身也会逐章跳过已缓存正文，因此实际抓取的只有缺口。
    expect(fetched, ['c2', 'c3']);
    expect(await cache.cachedChapterIds('book'), {'c0', 'c1', 'c2', 'c3'});
    await tester.pumpWidget(const SizedBox.shrink());
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
