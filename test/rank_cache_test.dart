import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/rank.dart';
import 'package:fqapp/pages/rank_page.dart';
import 'package:fqapp/services/rank_cache.dart';
import 'package:hive_flutter/hive_flutter.dart';

RankCatalog _catalog() => RankCatalog(
  rankId: 'r1',
  tabs: const [RankTab(name: '巅峰榜', algo: 5)],
  categories: const [RankCategory(name: '全部', id: 0)],
);

RankEntry _entry(String id, int position) => RankEntry(
  position: position,
  id: id,
  title: '书 $id',
  cover: '',
  author: '作者',
  category: '都市',
  creationStatus: 0,
);

/// In-memory stand-in so widget tests never touch real Hive I/O: the page's
/// unawaited saves would otherwise pend forever inside the FakeAsync zone.
class _MemoryRankCache extends RankCache {
  RankCatalogSnapshot? catalog;
  final Map<String, RankBoardSnapshot> boards = {};

  @override
  RankCatalogSnapshot? loadCatalog() => catalog;

  @override
  RankBoardSnapshot? loadBoard({
    required String rankId,
    required int algo,
    required int categoryId,
  }) => boards['$rankId|$algo|$categoryId'];

  @override
  Future<void> saveCatalog(RankCatalog catalogToSave) async {
    if (catalogToSave.isEmpty) return;
    catalog = RankCatalogSnapshot(
      catalog: catalogToSave,
      savedAt: DateTime.now(),
    );
  }

  @override
  Future<void> saveBoard({
    required String rankId,
    required int algo,
    required int categoryId,
    required RankBoard board,
  }) async {
    if (board.isEmpty) return;
    boards['$rankId|$algo|$categoryId'] = RankBoardSnapshot(
      board: board,
      savedAt: DateTime.now(),
    );
  }
}

RankPageLoader _countingLoader(
  int Function() counter,
  Future<RankBoard> Function() load,
) => ({
  required rankId,
  required algo,
  required categoryId,
  required offset,
  required startAt,
}) async {
  counter();
  return load();
};

void main() {
  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'fqapp-rank-cache-test-',
    );
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    RankCache.hiveReady = false;
  });

  test('catalog and board round trip through JSON', () {
    final catalog = RankCatalog.fromJson(_catalog().toJson());
    expect(catalog, isNotNull);
    expect(catalog!.rankId, 'r1');
    expect(catalog.tabs.single.name, '巅峰榜');
    expect(catalog.tabs.single.algo, 5);
    expect(catalog.categories.single.id, 0);

    final board = RankBoard(
      entries: [_entry('a', 1), _entry('b', 2)],
      hasMore: true,
    );
    final restored = RankBoard.fromJson(board.toJson());
    expect(restored.hasMore, isTrue);
    expect(restored.entries[1].id, 'b');
    expect(restored.entries[1].statusLabel, '完结');
    expect(restored.entries[1].metaLabel, contains('作者'));
  });

  test('real Hive save and load round trips, and the TTL drops stale rows',
      () async {
    RankCache.hiveReady = true;
    final cache = RankCache();
    await cache.saveCatalog(_catalog());
    await cache.saveBoard(
      rankId: 'r1',
      algo: 5,
      categoryId: 0,
      board: RankBoard(entries: [_entry('a', 1)], hasMore: true),
    );
    expect(cache.loadCatalog()?.catalog.rankId, 'r1');
    expect(cache.loadBoard(rankId: 'r1', algo: 5, categoryId: 0)?.board
        .entries
        .single
        .id, 'a');

    // Rewrite savedAt past the stale bound through the same box.
    final box = await Hive.openBox<dynamic>('rank_cache_v1');
    final raw = Map<String, dynamic>.from(box.get('r1|5|0') as Map);
    raw['savedAt'] =
        DateTime.now().millisecondsSinceEpoch -
        const Duration(hours: 25).inMilliseconds;
    await box.put('r1|5|0', raw);
    expect(cache.loadBoard(rankId: 'r1', algo: 5, categoryId: 0), isNull);
    await cache.close();
  });

  testWidgets('a fresh board snapshot is served without the network', (
    tester,
  ) async {
    final cache = _MemoryRankCache()
      ..catalog = RankCatalogSnapshot(catalog: _catalog(), savedAt: DateTime.now())
      ..boards['r1|5|0'] = RankBoardSnapshot(
        board: RankBoard(entries: [_entry('cached', 1)], hasMore: true),
        savedAt: DateTime.now(),
      );

    var pageLoads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RankPage(
          rankCache: cache,
          catalogLoader: () async => _catalog(),
          pageLoader: _countingLoader(
            () => pageLoads++,
            () async => RankBoard.empty,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(pageLoads, 0);
    expect(find.text('书 cached'), findsOneWidget);
  });

  testWidgets('a stale snapshot renders at once and the refresh replaces it', (
    tester,
  ) async {
    final cache = _MemoryRankCache()
      ..catalog = RankCatalogSnapshot(catalog: _catalog(), savedAt: DateTime.now())
      ..boards['r1|5|0'] = RankBoardSnapshot(
        board: RankBoard(entries: [_entry('cached', 1)], hasMore: true),
        // Older than RankCache.freshTtl, younger than staleTtl.
        savedAt: DateTime.now().subtract(const Duration(minutes: 10)),
      );

    final refreshed = Completer<RankBoard>();
    await tester.pumpWidget(
      MaterialApp(
        home: RankPage(
          rankCache: cache,
          catalogLoader: () async => _catalog(),
          pageLoader:
              ({
                required rankId,
                required algo,
                required categoryId,
                required offset,
                required startAt,
              }) => refreshed.future,
        ),
      ),
    );
    await tester.pump();

    // The cached list is on screen while the refresh is in flight.
    expect(find.text('书 cached'), findsOneWidget);
    expect(find.byKey(const Key('rank_retry')), findsNothing);

    refreshed.complete(
      RankBoard(entries: [_entry('fresh', 1)], hasMore: false),
    );
    await tester.pump();
    expect(find.text('书 fresh'), findsOneWidget);
  });

  testWidgets('a failed refresh keeps the cached board visible', (tester) async {
    final cache = _MemoryRankCache()
      ..catalog = RankCatalogSnapshot(catalog: _catalog(), savedAt: DateTime.now())
      ..boards['r1|5|0'] = RankBoardSnapshot(
        board: RankBoard(entries: [_entry('kept', 1)], hasMore: true),
        savedAt: DateTime.now().subtract(const Duration(minutes: 10)),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: RankPage(
          rankCache: cache,
          catalogLoader: () async => _catalog(),
          pageLoader:
              ({
                required rankId,
                required algo,
                required categoryId,
                required offset,
                required startAt,
              }) => throw StateError('offline'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('书 kept'), findsOneWidget);
    expect(find.byKey(const Key('rank_retry')), findsNothing);
  });

  testWidgets('a failed catalogue falls back to the stored one', (tester) async {
    final cache = _MemoryRankCache()
      ..catalog = RankCatalogSnapshot(catalog: _catalog(), savedAt: DateTime.now());

    await tester.pumpWidget(
      MaterialApp(
        home: RankPage(
          rankCache: cache,
          catalogLoader: () async => RankCatalog.empty,
          pageLoader:
              ({
                required rankId,
                required algo,
                required categoryId,
                required offset,
                required startAt,
              }) async => RankBoard(entries: [_entry('a', 1)], hasMore: false),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The cached catalogue drives the tab strip; the board still loads.
    expect(find.byKey(const Key('rank_tabs')), findsOneWidget);
    expect(find.text('书 a'), findsOneWidget);
  });
}
