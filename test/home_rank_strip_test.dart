import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_cell_blocks.dart';

/// The rank block previews one board and lets the strip switch boards in place
/// (`RankMixContentHolder.K7`: fetch the picked board, swap the preview, stay on
/// the page). These tests pin that behaviour, plus the fallback to 「更多」 when
/// the block carries no board ids.
void main() {
  MediaItem book(String id, String title) => MediaItem(
    id: id,
    title: title,
    cover: '',
    author: '',
    badge: '',
    ep: '',
    kind: 'book',
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

    await tester.tap(find.text('更多'));
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

      // 100dp 封面 + 12dp 列距：400dp 视口先露前三本，后段还没构建。
      expect(find.text('榜书1').hitTestable(), findsOneWidget);
      expect(find.text('榜书9'), findsNothing);

      // 大封面轨道横滑到后段名次。
      await tester.drag(find.byType(ListView), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(find.text('榜书9').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
