import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/home_feed_cache.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// The snapshot cache must bound the block tree as tightly as the flat item
/// list: pagination appends pages into a stream block, so an uncapped tree
/// grows on disk for as long as the user keeps scrolling.
void main() {
  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'fqapp-home-cell-budget-test-',
    );
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    HomeFeedCache.hiveReady = false;
  });

  MediaItem card(String id) => MediaItem(
    id: id,
    title: '剧 $id',
    cover: '',
    author: '',
    badge: '',
    ep: '',
    kind: 'video',
  );

  test(
    'cells share the flat item budget instead of growing with paging',
    () async {
      HomeFeedCache.hiveReady = true;
      final cache = HomeFeedCache();
      HomeCell streamPage(int from, int count) => HomeCell(
        showType: 385,
        name: '',
        id: '',
        style: const {},
        items: [for (var i = from; i < from + count; i++) card('n$i')],
        children: const [],
      );
      final container = HomeCell(
        showType: 384,
        name: '猜你喜欢',
        id: '',
        style: const {},
        items: const [],
        children: [streamPage(0, 50)],
      );
      final grid = HomeCell(
        showType: 386,
        name: '网格',
        id: '',
        style: const {},
        items: [for (var i = 0; i < 200; i++) card('c$i')],
        children: const [],
      );
      await cache.save(
        5,
        [card('flat')],
        hasMore: true,
        cells: [container, grid],
      );

      final snapshot = cache.load(5)!;
      final ids = <String>[];
      void collect(HomeCell cell) {
        ids.addAll(cell.items.map((item) => item.id));
        for (final child in cell.children) {
          collect(child);
        }
      }

      snapshot.cells.forEach(collect);
      expect(ids, hasLength(HomeFeedCache.maxItems));
      expect(ids.take(50), [for (var i = 0; i < 50; i++) 'n$i']);
      expect(ids.skip(50), [for (var i = 0; i < 70; i++) 'c$i']);
      await cache.close();
    },
  );

  test('a huge block list is capped like the item list', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(
      5,
      [card('flat')],
      hasMore: true,
      cells: [
        for (var i = 0; i < 200; i++)
          HomeCell(
            showType: 386,
            name: '块 $i',
            id: 'cell-$i',
            style: const {},
            items: [card('c$i')],
            children: const [],
          ),
      ],
    );
    final snapshot = cache.load(5)!;
    expect(snapshot.cells, hasLength(HomeFeedCache.maxItems));
    expect(snapshot.cells.last.id, 'cell-119');
    await cache.close();
  });
}
