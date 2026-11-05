import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/shuqi_detail_page.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/fakes.dart';

/// Focused cover for the upstream DetailPage port (Wenku8_Flutter ebcd7f1):
/// archive header + sections, inline volume catalogue, cache marks, dock, and
/// the same components on the 书旗 detail page.
void main() {
  testWidgets('detail uses the archive header, sections and glass dock', (
    tester,
  ) async {
    await _pumpDetail(tester);
    expect(find.text('图书详情'), findsOneWidget);
    expect(find.text('简介'), findsOneWidget);
    expect(find.text('01 / SYNOPSIS'), findsOneWidget);
    expect(find.text('02 / CONTENTS'), findsOneWidget);
    await _dragUntil(
      tester,
      find.byKey(const ValueKey('detail-directory-entry-0')),
    );
    expect(
      find.byKey(const ValueKey('detail-directory-entry-0')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<GlassPillButton>(find.byKey(const Key('detail_read_button')))
          .onPressed,
      isNotNull,
    );
    expect(find.byKey(const Key('detail_shelf_button')), findsOneWidget);
  });

  testWidgets('the catalogue groups chapters under expandable volumes', (
    tester,
  ) async {
    await _pumpDetail(tester);
    final volume = find.byKey(const ValueKey('detail-volume-第一卷 · 初见#0'));
    await _dragUntil(tester, volume);
    expect(volume, findsOneWidget);
    await _dragUntil(
      tester,
      find.byKey(const ValueKey('detail-directory-entry-0')),
    );
    expect(
      find.byKey(const ValueKey('detail-directory-entry-0')),
      findsOneWidget,
    );

    await tester.tap(volume);
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey('detail-directory-entry-0'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    await tester.tap(volume);
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey('detail-directory-entry-0'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets('the order toggle flips the inline catalogue', (tester) async {
    await _pumpDetail(tester);
    final toggle = find.byKey(const Key('detail-catalogue-order'));
    await _dragUntil(tester, toggle);
    expect(find.text('正序'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('倒序'), findsOneWidget);
    expect(find.text('正序'), findsNothing);
  });

  testWidgets('chapter cache marks come from the injected cache', (
    tester,
  ) async {
    final cache = MemoryChapterCache();
    await cache.write(
      bookId: 'book',
      chapterId: 'first',
      title: '第一章',
      text: '离线正文',
    );
    await _pumpDetail(tester, cache: cache);
    final volume = find.byKey(const ValueKey('detail-volume-第一卷 · 初见#0'));
    await _dragUntil(tester, volume);
    expect(find.textContaining('已缓存 1 / 2'), findsOneWidget);
    await _dragUntil(
      tester,
      find.byKey(const ValueKey('detail-directory-entry-0')),
    );
    expect(
      find.byKey(
        const ValueKey('detail-chapter-cached-0'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets('书旗 detail adopts the archive layout and keeps 书旗 source', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ShuqiDetailPage(
          bookId: '34078',
          bookLoader: (_) async => {
            'data': {
              'bookId': '34078',
              'name': '凡人修仙传',
              'author': '忘语',
              'intro': '一个普通山村小子',
              'kind': '玄幻',
              'wordCount': '2451万字',
              'status': '完结',
              'chapterTotalNum': 1,
            },
          },
          tocLoader: (_) async => {
            'data': {
              'path': 'h5',
              'total': 1,
              'chapters': [
                {'chapterId': '2180322', 'title': '第1章 山边小村', 'isVip': false},
              ],
            },
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('书籍详情'), findsOneWidget);
    expect(find.text('02 / CONTENTS'), findsOneWidget);
    expect(find.textContaining('书旗小说'), findsOneWidget);
    expect(find.byKey(const ValueKey('shuqi-chapter-0')), findsOneWidget);
    expect(find.text('开始阅读'), findsOneWidget);
  });
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  MemoryChapterCache? cache,
}) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: DetailPage(
        item: _book,
        readerStore: MemoryReaderStore(),
        chapterCache: cache ?? MemoryChapterCache(),
        detailLoader: (id, {String tab = '小说'}) async => {
          'data': {'abstract': '一段关于宗门成长的故事。', 'creation_status': '1'},
        },
        directoryLoader: (id, {String tab = '小说'}) async => [
          [
            Chapter(itemId: 'first', title: '第一章', volumeName: '第一卷 · 初见'),
            Chapter(itemId: 'second', title: '第二章', volumeName: '第一卷 · 初见'),
          ],
          [Chapter(itemId: 'third', title: '第三章', volumeName: '终卷 · 星河')],
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Drags the ported page until [target] has been built (the catalogue is a
/// lazy sliver below the intro).
Future<void> _dragUntil(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 20 && target.evaluate().isEmpty; i++) {
    await tester.drag(
      find.byKey(const Key('detail_scroll')),
      const Offset(0, -300),
    );
    await tester.pump();
  }
  expect(target, findsWidgets);
}

final _book = MediaItem(
  id: 'book',
  title: '开局废弃宗门，我召唤了大帝长老',
  cover: '',
  author: '香瓜贼甜',
  badge: '玄幻脑洞',
  ep: '',
  kind: 'book',
);
