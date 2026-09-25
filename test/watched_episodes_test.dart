import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/watched_episodes.dart';

import 'support/fakes.dart';

/// F07：已看集按**剧集/视频 id** 记录，与续播位置分开，迁移不补造中间集。
///
/// 官方依据：选集格子判「这一集看过」用
/// `VideoGlobalManager.b(seriesId).c(vid)`（`hj3/r0.java:445` 的
/// `bf3.b.b.q(seriesId, vid, ctx)`），存储是 `video_progress` 一族 SP，
/// 键就是 vid（`com/dragon/read/video/d.java:18-20`）。
void main() {
  List<Chapter> episodes(int count) => [
    for (var i = 0; i < count; i++)
      Chapter(itemId: 'v${i + 1}', title: '第 ${i + 1} 集', volumeName: '剧集'),
  ];

  test('marking stores the ids and never the indexes', () async {
    final store = MemoryReaderStore();
    final watched = WatchedEpisodes(store);
    await watched.mark('s1', ['v3']);
    expect(await watched.ids('s1'), {'v3'});
    // 再标记是并集，不覆盖。
    await watched.mark('s1', ['v5', 'v3']);
    expect(await watched.ids('s1'), {'v3', 'v5'});
  });

  test('a reordered list still resolves the same episodes', () async {
    final store = MemoryReaderStore();
    final watched = WatchedEpisodes(store);
    final before = episodes(10);
    await watched.mark('s1', [before[7].itemId]);
    // 列表顺序变了：同一集换了位置，已看标记必须跟着 id 走。
    final reordered = [...before.reversed];
    final ids = await watched.ids('s1');
    expect(watchedIndexes(ids, before), {7});
    expect(watchedIndexes(ids, reordered), {2});
  });

  test('migration marks only the episode from the old record', () async {
    final store = MemoryReaderStore();
    final watched = WatchedEpisodes(store);
    final list = episodes(20);
    final migrated = await watched.migrateFromHistory(
      seriesId: 's1',
      // 旧记录：最后看到第 12 集（下标 11）。
      saved: {'episode': 11, 'episodeId': 'v12'},
      episodes: list,
    );
    expect(migrated, {'v12'});
    // 关键断言：前面的 11 集**不能**被补造成已看。
    expect(await watched.ids('s1'), {'v12'});
  });

  test('migration prefers the stable id when the index disagrees', () async {
    final store = MemoryReaderStore();
    final watched = WatchedEpisodes(store);
    final list = episodes(20);
    await watched.migrateFromHistory(
      seriesId: 's1',
      saved: {'episode': 0, 'episodeId': 'v9'},
      episodes: list,
    );
    expect(await watched.ids('s1'), {'v9'});
  });

  test('migration runs once per record', () async {
    final store = MemoryReaderStore();
    final watched = WatchedEpisodes(store);
    final list = episodes(5);
    await watched.migrateFromHistory(
      seriesId: 's1',
      saved: {'episode': 2, 'episodeId': 'v3', 'watchedMigrated': true},
      episodes: list,
    );
    expect(await watched.ids('s1'), isEmpty);
  });

  test('a record without a usable episode migrates nothing', () async {
    final store = MemoryReaderStore();
    final watched = WatchedEpisodes(store);
    await watched.migrateFromHistory(
      seriesId: 's1',
      saved: {'episode': 99},
      episodes: episodes(3),
    );
    expect(await watched.ids('s1'), isEmpty);
  });

  test('forgetting a series clears its watched set', () async {
    final store = MemoryReaderStore();
    final watched = WatchedEpisodes(store);
    await watched.mark('s1', ['v1']);
    await store.forgetWatchedEpisodes('s1');
    expect(await watched.ids('s1'), isEmpty);
  });

  test('resumeIndex tolerates the legacy shapes', () {
    final list = episodes(5);
    expect(WatchedEpisodes.resumeIndex({'episode': 3}, list), 3);
    expect(WatchedEpisodes.resumeIndex({'episodeId': 'v2'}, list), 1);
    expect(WatchedEpisodes.resumeIndex({'episode': -1}, list), isNull);
    expect(WatchedEpisodes.resumeIndex({'episode': 2.5}, list), isNull);
    expect(WatchedEpisodes.resumeIndex({}, list), isNull);
  });

  test('watchedIndexes maps unknown ids away', () {
    expect(watchedIndexes({'v1', 'nope'}, episodes(3)), {0});
    expect(watchedIndexes({}, episodes(3)), isEmpty);
  });
}
