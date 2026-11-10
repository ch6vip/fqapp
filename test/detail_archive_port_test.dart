import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/shuqi_detail_page.dart';
import 'package:fqapp/services/catalogue_order_preferences.dart';
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
    expect(find.text('小说详情'), findsOneWidget);
    expect(find.text('图书详情'), findsNothing);
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

  testWidgets('the header and meta source follow the content kind', (
    tester,
  ) async {
    await _pumpDetail(tester, item: _drama);
    expect(find.text('短剧详情'), findsOneWidget);
    expect(find.text('小说详情'), findsNothing);
    expect(find.text('图书详情'), findsNothing);
    // The identity meta carries the matching 番茄 source, not 番茄小说.
    expect(find.textContaining('番茄短剧'), findsOneWidget);
    expect(find.textContaining('番茄小说'), findsNothing);
  });

  testWidgets('the ID row and reviews stay above the inline catalogue', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      extras: const DetailExtras(
        comments: BookCommentPage(
          comments: [BookComment(id: 'c1', text: '很好看', userName: '读者')],
          totalCount: 1,
        ),
      ),
    );
    // Built with the intro sliver, so a long catalogue cannot push it out of
    // reach.
    final idRow = find.byKey(const Key('detail_id_row'));
    expect(idRow, findsOneWidget);
    final contents = find.text('02 / CONTENTS');
    expect(contents, findsOneWidget);
    expect(
      tester.getTopLeft(idRow).dy,
      lessThan(tester.getTopLeft(contents).dy),
    );
    // Reviews stay above the catalogue heading as they did after the preview
    // block in the old layout.
    final reviews = find.text('03 / REVIEWS');
    expect(reviews, findsOneWidget);
    expect(
      tester.getTopLeft(reviews).dy,
      lessThan(tester.getTopLeft(contents).dy),
    );
  });

  testWidgets('the catalogue order is persisted across visits', (tester) async {
    SharedPreferences.setMockInitialValues({
      CatalogueOrderPreferences.key: true,
    });
    CatalogueOrderPreferences.instance.resetForTest();
    addTearDown(CatalogueOrderPreferences.instance.resetForTest);
    await _pumpDetail(tester);
    final toggle = find.byKey(const Key('detail-catalogue-order'));
    await _dragUntil(tester, toggle);
    // Restored from SharedPreferences, not the default 正序.
    expect(find.text('倒序'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('正序'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(CatalogueOrderPreferences.key), isFalse);

    // A fresh page instance reads the written order.
    CatalogueOrderPreferences.instance.resetForTest();
    await _pumpDetail(tester);
    await _dragUntil(tester, toggle);
    expect(find.text('正序'), findsOneWidget);
    expect(find.text('倒序'), findsNothing);
  });

  testWidgets('书旗目录 only builds chapter rows near the viewport', (
    tester,
  ) async {
    final chapters = List.generate(
      400,
      (i) => {'chapterId': 'c$i', 'title': '第 ${i + 1} 章', 'isVip': false},
    );
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
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
            },
          },
          tocLoader: (_) async => {
            'data': {'path': 'h5', 'total': 400, 'chapters': chapters},
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('shuqi-chapter-0'), skipOffstage: false),
      findsOneWidget,
    );
    // A 400-chapter catalogue must not build every row on the first frame.
    expect(
      find.byKey(const ValueKey('shuqi-chapter-399'), skipOffstage: false),
      findsNothing,
    );
  });
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  MemoryChapterCache? cache,
  MediaItem? item,
  DetailExtras? extras,
}) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: DetailPage(
        item: item ?? _book,
        readerStore: MemoryReaderStore(),
        chapterCache: cache ?? MemoryChapterCache(),
        extrasLoader: extras == null ? null : (_) async => extras,
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

final _drama = MediaItem(
  id: 'drama',
  title: '短剧标题',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'video',
);
