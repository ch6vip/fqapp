import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/rank.dart';
import 'package:fqapp/pages/rank_page.dart';

const _catalog = RankCatalog(
  rankId: '7098235271900037133',
  tabs: [
    RankTab(name: '巅峰榜', algo: 200),
    RankTab(name: '完本榜', algo: 100),
  ],
  categories: [
    RankCategory(name: '全部', id: 0),
    RankCategory(name: '穿越', id: 37),
  ],
);

RankBoard _board({bool hasMore = false, int count = 2, int startAt = 1}) =>
    RankBoard(
      hasMore: hasMore,
      entries: [
        for (var i = 0; i < count; i++)
          RankEntry(
            position: startAt + i,
            id: 'book-$startAt-$i',
            title: '锦衣夜行九万里 $startAt-$i',
          ),
      ],
    );

void main() {
  Future<void> pumpRankPage(WidgetTester tester, RankPageLoader pageLoader) =>
      tester.pumpWidget(
        MaterialApp(
          home: RankPage(
            catalogLoader: () async => _catalog,
            pageLoader: pageLoader,
          ),
        ),
      );

  testWidgets('a stale load-more cannot leave the flag stuck', (tester) async {
    final stale = Completer<RankBoard>();
    var loadMoreCalls = 0;
    await pumpRankPage(tester, ({
      required rankId,
      required algo,
      required categoryId,
      required offset,
      required startAt,
    }) {
      if (offset == 0) {
        return Future.value(_board(hasMore: true, count: 30));
      }
      loadMoreCalls++;
      return stale.future;
    });
    await tester.pumpAndSettle();

    // Start a load-more for the first rank and leave it in flight.
    await tester.drag(
      find.byKey(const Key('rank_list')),
      const Offset(0, -6000),
    );
    await tester.pump();
    expect(loadMoreCalls, 1);

    // Switch rank while that request is still pending.
    await tester.tap(find.byKey(const ValueKey('rank_tab_100')));
    await tester.pumpAndSettle();

    // The stale request now finishes; it must not resurrect the flag.
    stale.complete(_board(startAt: 31, count: 5));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Pagination still works for the newly selected rank.
    await tester.drag(
      find.byKey(const Key('rank_list')),
      const Offset(0, -6000),
    );
    await tester.pump();
    expect(loadMoreCalls, 2);
  });

  testWidgets('a failed load-more surfaces an inline retry', (tester) async {
    var failLoadMore = true;
    var loadMoreCalls = 0;
    await pumpRankPage(tester, ({
      required rankId,
      required algo,
      required categoryId,
      required offset,
      required startAt,
    }) async {
      if (offset == 0) {
        return _board(hasMore: true, count: 30);
      }
      loadMoreCalls++;
      if (failLoadMore) throw StateError('offline');
      return _board(startAt: startAt, count: 5);
    });
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('rank_list')),
      const Offset(0, -6000),
    );
    await tester.pumpAndSettle();

    expect(loadMoreCalls, greaterThanOrEqualTo(1));
    expect(find.byKey(const Key('rank_load_more_retry')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    final retry = find.byKey(const Key('rank_load_more_retry'));
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    expect(retry, findsOneWidget);

    failLoadMore = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('rank_load_more_retry')), findsNothing);
    expect(find.text('31'), findsOneWidget);
  });
}
