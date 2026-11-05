import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_cell_blocks.dart';
import 'package:fqapp/widgets/home/home_rank_shelf.dart';

/// The rank block previews one board and lets the strip switch boards in place
/// (`RankMixContentHolder.K7`: fetch the picked board, swap the preview, stay on
/// the page). These tests pin that behaviour, plus the fallback to 「更多」 when
/// the block carries no board ids.
void main() {
  MediaItem book(
    String id,
    String title, {
    String author = '',
    String readCount = '',
    int creationStatus = -1,
  }) => MediaItem(
    id: id,
    title: title,
    cover: '',
    author: author,
    badge: '',
    ep: '',
    kind: 'book',
    readCount: readCount,
    creationStatus: creationStatus,
  );

  HomeCell rankCell({bool withBoards = true}) => HomeCell(
    showType: 511,
    name: '排行榜',
    id: withBoards ? '7098235271900037133' : '',
    style: const {},
    extra: withBoards
        ? const {
            'rank_with_category_data': {
              'rank_algo_list': [
                {'rank_algo': 101, 'rank_name': '推荐榜'},
                {'rank_algo': 100, 'rank_name': '完本榜'},
              ],
            },
          }
        : const {},
    items: const [],
    children: [
      HomeCell(
        showType: 512,
        name: '',
        id: '',
        style: const {},
        items: [book('r1', '预览书一')],
        children: const [],
      ),
    ],
  );

  testWidgets('the strip swaps the preview for the picked board', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    final calls = <String>[];
    var moreTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeRankCell(
            cell: rankCell(),
            onOpen: (_) {},
            onMore: () => moreTaps++,
            loadBoard: (rankId, algo) async {
              calls.add('$rankId/$algo');
              return [book('b$algo', '完本榜书一')];
            },
          ),
        ),
      ),
    );

    // 首屏是上游给的预览，榜名条第一项选中。
    expect(find.text('预览书一'), findsOneWidget);
    expect(find.text('推荐榜'), findsOneWidget);
    expect(find.text('完本榜'), findsOneWidget);

    await tester.tap(find.text('完本榜'));
    await tester.pumpAndSettle();

    // 只按选中的那一榜拉数据，rank_id 用区块自带的 cell_id_str。
    expect(calls, ['7098235271900037133/100']);
    expect(find.text('完本榜书一'), findsOneWidget);
    expect(find.text('预览书一'), findsNothing);
    expect(moreTaps, 0);
  });

  testWidgets('without board ids the strip falls back to 「更多」', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    var moreTaps = 0;
    var loads = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeRankCell(
            cell: rankCell(withBoards: false),
            onOpen: (_) {},
            onMore: () => moreTaps++,
            loadBoard: (rankId, algo) async {
              loads++;
              return const [];
            },
          ),
        ),
      ),
    );

    // 没有榜名条时退回标题行，不再有可点的榜名。
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('推荐榜'), findsNothing);

    await tester.tap(find.text('完整榜单'));
    await tester.pumpAndSettle();

    expect(moreTaps, 1);
    expect(loads, 0);
  });

  testWidgets('a failing board load keeps the current preview', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeRankCell(
            cell: rankCell(),
            onOpen: (_) {},
            onMore: () {},
            loadBoard: (rankId, algo) async => throw StateError('offline'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('完本榜'));
    await tester.pumpAndSettle();

    // 拉不到就留在原来的预览上，不能把整块清空。
    expect(find.text('预览书一'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('rank rail', () {
    HomeCell twelveBookCell() => HomeCell(
      showType: 511,
      name: '排行榜',
      id: '',
      style: const {},
      items: const [],
      children: [
        for (var i = 1; i <= 12; i++)
          HomeCell(
            showType: 512,
            name: '',
            id: '',
            style: const {},
            items: [book('r$i', '榜书$i')],
            children: const [],
          ),
      ],
    );

    testWidgets('the rail scrolls sideways to later ranks', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeRankCell(
              cell: twelveBookCell(),
              onOpen: (_) {},
              onMore: () {},
            ),
          ),
        ),
      );

      // 首屏停在第 1 名，书架下方是真实名次与翻页器。
      expect(find.text('榜书1'), findsOneWidget);
      expect(find.text('01 / 12'), findsOneWidget);

      // 翻页器把书架推到后段名次（书脊阵列由画布绘制，书名在信息行里）。
      for (var i = 0; i < 8; i++) {
        await tester.tap(find.byKey(const Key('home_rank_next')));
        await tester.pumpAndSettle();
      }
      expect(find.text('09 / 12'), findsOneWidget);
      expect(find.text('榜书9'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('archive info row and fallback rail', () {
    Future<void> pumpShelf(
      WidgetTester tester,
      List<MediaItem> books, {
      bool flat = false,
    }) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeRankShelf(books: books, flat: flat, onOpen: (_) {}),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets(
      'info row shows NO. code with reading count, author and status',
      (tester) async {
        await pumpShelf(tester, [
          book(
            'r1',
            '万古剑主',
            author: '云中客',
            readCount: '286万人在读',
            creationStatus: 1,
          ),
        ]);

        expect(find.text('NO.001 / 286万人在读'), findsOneWidget);
        expect(find.text('云中客 · 连载中'), findsOneWidget);
      },
    );

    testWidgets('unknown reading count leaves only the rank number', (
      tester,
    ) async {
      await pumpShelf(tester, [book('r1', '榜书一', author: '甲')]);

      // 没有在读人数时不能拿媒介名（「小说」）冒充。
      expect(find.text('NO.001'), findsOneWidget);
      expect(find.textContaining('NO.001 /'), findsNothing);
      expect(find.text('甲'), findsOneWidget);
    });

    testWidgets(
      'flat fallback is a swipeable cover rail with the same info row',
      (tester) async {
        await pumpShelf(tester, [
          book('r1', '榜书一', author: '甲', readCount: '12万人在读'),
          book('r2', '榜书二', author: '乙', readCount: '80000'),
        ], flat: true);

        // 平面轨道没有立体画布，只有封面和共用的信息行。
        expect(find.byKey(const Key('home_rank_flat_rail')), findsOneWidget);
        expect(find.text('NO.001 / 12万人在读'), findsOneWidget);

        await tester.tap(find.byKey(const Key('home_rank_next')));
        await tester.pumpAndSettle();
        expect(find.text('NO.002 / 8万人在读'), findsOneWidget);
        expect(find.text('02 / 02'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('flat rail can reach the last rank', (tester) async {
      final books = [for (var i = 1; i <= 12; i++) book('r$i', '榜书$i')];
      await pumpShelf(tester, books, flat: true);

      for (var i = 0; i < 11; i++) {
        await tester.tap(find.byKey(const Key('home_rank_next')));
        await tester.pumpAndSettle();
      }

      // 翻页器走到 12/12 时轨道也必须真的停在最后一本：400dp 下封面
      // 116、页距 128，偏移就是 11×128。
      expect(find.text('12 / 12'), findsOneWidget);
      final rail = tester.widget<ListView>(
        find.byKey(const Key('home_rank_flat_rail')),
      );
      expect(rail.controller!.offset, closeTo(11 * 128, 0.5));
    });

    testWidgets('rebuilding with the same books keeps the flat position', (
      tester,
    ) async {
      final books = [for (var i = 1; i <= 8; i++) book('r$i', '榜书$i')];
      await pumpShelf(tester, books, flat: true);
      await tester.tap(find.byKey(const Key('home_rank_next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home_rank_next')));
      await tester.pumpAndSettle();
      expect(find.text('03 / 08'), findsOneWidget);

      // 父级重建会重新 flatten 出新的 List，但榜单没换，不能跳回第一本。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeRankShelf(
              books: List.of(books),
              flat: true,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('03 / 08'), findsOneWidget);
    });

    testWidgets('switching boards rewinds the flat rail', (tester) async {
      final first = [for (var i = 1; i <= 8; i++) book('r$i', '榜书$i')];
      await pumpShelf(tester, first, flat: true);
      await tester.tap(find.byKey(const Key('home_rank_next')));
      await tester.pumpAndSettle();
      expect(find.text('02 / 08'), findsOneWidget);

      final second = [for (var i = 1; i <= 8; i++) book('x$i', '新榜$i')];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeRankShelf(books: second, flat: true, onOpen: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('01 / 08'), findsOneWidget);
      expect(find.text('新榜1'), findsOneWidget);
    });
  });
}
