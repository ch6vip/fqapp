import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/detail/detail_chapter_row.dart';
import 'package:fqapp/widgets/detail/detail_read_bar.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('the directory preview is centred on the saved chapter', (
    tester,
  ) async {
    await _pumpBook(
      tester,
      store: MemoryReaderStore(
        entry: {'kind': 'book', 'chapterId': 'chapter-23', 'episode': 0},
      ),
    );
    final rows = tester
        .widgetList<DetailChapterRow>(
          find.byType(DetailChapterRow, skipOffstage: false),
        )
        .toList();
    expect(rows.map((row) => row.chapter.title), [
      '第22章 故事的另一种可能',
      '第23章 故事的另一种可能',
      '第24章 故事的另一种可能',
    ]);
    expect(rows.map((row) => row.current), [false, true, false]);
  });

  testWidgets('without progress the preview falls back to the first three', (
    tester,
  ) async {
    await _pumpBook(tester);
    final rows = tester
        .widgetList<DetailChapterRow>(
          find.byType(DetailChapterRow, skipOffstage: false),
        )
        .toList();
    expect(rows.map((row) => row.chapter.title), [
      '第1章 故事的另一种可能',
      '第2章 故事的另一种可能',
      '第3章 故事的另一种可能',
    ]);
    expect(rows.every((row) => !row.current), isTrue);
  });

  testWidgets('the rating appears exactly once on the page', (tester) async {
    await _pumpBook(
      tester,
      detailPayload: {
        'data': {
          'abstract': _description,
          'score': '8.7',
          'read_count': '124000',
        },
      },
    );
    expect(find.text('8.7'), findsOneWidget);
    expect(find.textContaining('12.4万人在读'), findsOneWidget);
    // 旧版在书评区又放了一张评分卡。
    expect(find.byKey(const Key('detail_score_card')), findsNothing);
    expect(find.byKey(const Key('detail_stats_row')), findsNothing);
  });

  testWidgets('the bottom bar stays mounted and disabled while loading', (
    tester,
  ) async {
    final pending = Completer<List<List<Chapter>>>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(const []);
    });
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          item: _book,
          readerStore: MemoryReaderStore(),
          detailLoader: (id, {String tab = '小说'}) async => {},
          directoryLoader: (id, {String tab = '小说'}) => pending.future,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final bar = find.byType(DetailReadBar);
    expect(bar, findsOneWidget);
    expect(tester.widget<DetailReadBar>(bar).enabled, isFalse);
    expect(find.byKey(const Key('detail_read_button')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final kind in ['book', 'audio', 'manga']) {
    testWidgets('$kind uses the plain 简介 heading', (tester) async {
      await _pumpBook(
        tester,
        item: MediaItem(
          id: 'detail-$kind',
          title: '标题',
          cover: '',
          author: '作者',
          badge: '',
          ep: '',
          kind: kind,
        ),
      );
      expect(find.text('简介', skipOffstage: false), findsOneWidget);
      expect(find.text('书籍简介', skipOffstage: false), findsNothing);
    });
  }

  testWidgets('e-ink renders the rating and primary action in black', (
    tester,
  ) async {
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = false);
    await _pumpBook(
      tester,
      detailPayload: {
        'data': {
          'abstract': _description,
          'score': '8.7',
          'read_count': '124000',
        },
      },
    );
    expect(find.byKey(const Key('detail_masthead_wash')), findsNothing);
    final star = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('detail_rating_line')),
        matching: find.byIcon(LucideIcons.star),
      ),
    );
    expect(star.color, Colors.black);
    final pill = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const Key('detail_read_button')),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((pill.decoration! as BoxDecoration).color, Colors.black);
  });
}

Future<void> _pumpBook(
  WidgetTester tester, {
  MemoryReaderStore? store,
  Map<String, dynamic>? detailPayload,
  MediaItem? item,
}) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: DetailPage(
        item: item ?? _book,
        readerStore: store ?? MemoryReaderStore(),
        detailLoader: (id, {String tab = '小说'}) async =>
            detailPayload ??
            {
              'data': {'abstract': _description},
            },
        directoryLoader: (id, {String tab = '小说'}) async => [
          List.generate(
            146,
            (index) => Chapter(
              itemId: 'chapter-${index + 1}',
              title: '第${index + 1}章 故事的另一种可能',
              volumeName: index < 73 ? '第一卷 · 初见' : '终卷 · 星河',
            ),
          ),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _book = MediaItem(
  id: 'detail-design-book',
  title: '开局废弃宗门，我召唤了大帝长老',
  cover: '',
  author: '香瓜贼甜',
  badge: '玄幻脑洞',
  ep: '',
  kind: 'book',
);

const _description =
    '苏狂身穿玄幻世界，激活无敌宗门系统，开局就召唤出了大帝境强者！\n'
    '只要招收天才进宗，还能继续抽取各类强者！\n'
    '而且弟子的修为精进，也能百倍返还给苏狂！\n'
    '于是，一段关于宗门、成长与奇遇的故事，就这样开始。';
