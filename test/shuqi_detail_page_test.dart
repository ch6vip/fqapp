import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/pages/shuqi_detail_page.dart';

void main() {
  testWidgets('a toc failure keeps the book detail and offers a retry', (
    tester,
  ) async {
    var tocCalls = 0;
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
              'coverUrl': '',
              'wordCount': '2451万字',
              'lastChapter': '第2451章',
              'status': '完结',
              'chapterTotalNum': 2451,
            },
          },
          tocLoader: (_) async {
            tocCalls++;
            if (tocCalls == 1) throw StateError('toc down');
            return {
              'data': {
                'path': 'h5',
                'total': 1,
                'chapters': [
                  {'chapterId': '2180322', 'title': '第1章 山边小村', 'isVip': false},
                ],
              },
            };
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 详情已经拿到，不能因为目录失败而整页报错。
    expect(find.text('忘语'), findsOneWidget);
    expect(find.text('一个普通山村小子'), findsOneWidget);
    expect(find.text('加载失败，请稍后重试'), findsOneWidget);
    // 「开始阅读」在目录为空时禁用，但详情本身仍然可见。
    expect(find.text('目录未加载'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
    await tester.pumpAndSettle();

    expect(tocCalls, 2);
    expect(find.text('加载失败，请稍后重试'), findsNothing);
    expect(find.text('第1章 山边小村'), findsOneWidget);
    expect(find.text('共 1 章'), findsOneWidget);
  });

  testWidgets('opening a chapter gives the reader a store that drops history', (
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
              'coverUrl': '',
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

    await tester.tap(find.text('开始阅读'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(reader.localOnly, isTrue);
    final store = reader.readerStore;
    expect(
      store,
      isNotNull,
      reason: 'the reader must not fall back to the global history store',
    );

    // ReaderPage 的 _persistProgress/_settleReadTime 会写这个 store；书旗是
    // 只读源，所有写入必须被丢弃。
    await store!.addHistory({
      'id': 'shuqi:34078',
      'kind': 'book',
      'bookId': 'shuqi:34078',
    });
    await store.accumulateReadTime('shuqi:34078', 'book', 30);
    await store.updateProgress('shuqi:34078', 0, 0.5);
    expect(await store.historyEntry('shuqi:34078'), isNull);

    // 撤掉阅读器，别让还在跑的正文请求把 setState 带出测试。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
