import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/drama_download_store.dart';

void main() {
  late Directory temp;
  late Directory videoDir;
  late HiveDramaDownloadStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fqapp-drama-store-');
    Hive.init(temp.path);
    videoDir = Directory('${temp.path}${Platform.pathSeparator}offline-video')
      ..createSync();
    store = HiveDramaDownloadStore(directoryResolver: () async => videoDir);
  });

  tearDown(() async {
    await Hive.close();
    try {
      await Hive.deleteBoxFromDisk('drama_download_v1');
    } catch (_) {}
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  CachedEpisode episode({
    String itemId = 'ep1',
    String seriesId = 'series1',
    int index = 0,
    int bytes = 1024,
    bool withFile = true,
    int? cachedAt,
  }) {
    final path =
        '${videoDir.path}${Platform.pathSeparator}$itemId.mp4';
    if (withFile) {
      File(path).writeAsBytesSync(List.filled(bytes, 1));
    }
    return CachedEpisode(
      seriesId: seriesId,
      itemId: itemId,
      title: '第${index + 1}集',
      index: index,
      keyHex: '0102',
      height: 1080,
      variantName: '1080P',
      bytes: bytes,
      filePath: path,
      cachedAt: cachedAt ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  test('saveEpisode/isDownloaded/episode 往返一致', () async {
    await store.saveEpisode(episode());
    expect(await store.isDownloaded('ep1'), isTrue);
    expect(await store.isDownloaded('ep2'), isFalse);
    final record = await store.episode('ep1');
    expect(record, isNotNull);
    expect(record!.seriesId, 'series1');
    expect(record.keyHex, '0102');
    expect(record.bytes, 1024);
  });

  test('toSource 生成 file:// 取流结果并保留画质档', () async {
    await store.saveEpisode(episode());
    final source = (await store.episode('ep1'))!.toSource();
    expect(source.url.startsWith('file://'), isTrue);
    expect(source.keyHex, '0102');
    expect(source.variants, hasLength(1));
    expect(source.variants.first.name, '1080P');
    expect(source.variants.first.height, 1080);
  });

  test('损坏记录按未缓存处理，不给出不可回放的取流结果', () async {
    final box = await Hive.openBox<dynamic>('drama_download_v1');
    await box.put('episode:bad', {'seriesId': 'series1'});
    expect(await store.isDownloaded('bad'), isFalse);
    expect(await store.episode('bad'), isNull);
  });

  test('dramas 按剧聚合、集按 index 排序、剧按最近缓存排序', () async {
    await store.ensureCatalogue(
      CachedDrama(
        id: 'series1',
        title: '测试剧',
        cover: 'cover.jpg',
        episodes: [
          Chapter(itemId: 'ep1', title: '第一集', volumeName: ''),
          Chapter(itemId: 'ep2', title: '第二集', volumeName: ''),
        ],
      ),
    );
    // 显式给每集一个 cachedAt：剧的排序取各集 cachedAt 的最大值，若两个剧
    // 落在同一毫秒，`List.sort` 的比较返回 0 且不保证稳定——用真实时钟会
    // 变成偶发失败（CI 上实测到过 series1/series2 顺序反转）。这里直接钉死
    // 时间戳，让断言只依赖实现逻辑，不依赖计时精度。
    await store.saveEpisode(
      episode(itemId: 'ep1', index: 1, cachedAt: 1000),
    );
    await store.saveEpisode(
      episode(itemId: 'ep2', index: 0, cachedAt: 2000),
    );
    await store.saveEpisode(
      episode(itemId: 'ep9', seriesId: 'series2', cachedAt: 3000),
    );

    final dramas = await store.dramas();
    expect(dramas, hasLength(2));
    // series2 的最后缓存时间更晚（3000 > 2000），排前面。
    expect(dramas.first.drama.id, 'series2');
    final series1 = dramas.lastWhere((item) => item.drama.id == 'series1');
    expect(series1.drama.title, '测试剧');
    expect(series1.episodes.map((e) => e.itemId).toList(), ['ep2', 'ep1']);
    expect(series1.bytes, 2048);
  });

  test('removeEpisode 连带删除视频文件', () async {
    final record = episode();
    await store.saveEpisode(record);
    expect(File(record.filePath).existsSync(), isTrue);
    await store.removeEpisode('ep1');
    expect(await store.isDownloaded('ep1'), isFalse);
    expect(File(record.filePath).existsSync(), isFalse);
  });

  test('removeDrama 清空该剧全部集与文件', () async {
    await store.saveEpisode(episode(itemId: 'ep1'));
    await store.saveEpisode(episode(itemId: 'ep2', index: 1));
    await store.removeDrama('series1');
    expect(await store.dramas(), isEmpty);
    expect(await store.isDownloaded('ep1'), isFalse);
    expect(await store.isDownloaded('ep2'), isFalse);
  });

  test('目录记录在集全无时不被 dramas 丢弃（下载中状态可见）', () async {
    await store.ensureCatalogue(
      CachedDrama(
        id: 'series1',
        title: '测试剧',
        cover: '',
        episodes: [Chapter(itemId: 'ep1', title: '第一集', volumeName: '')],
      ),
    );
    // 集还没完成：dramas() 不返回它（管理页的任务区显示），但目录留着。
    expect(await store.hasCatalogue('series1'), isTrue);
    expect(await store.dramas(), isEmpty);
  });

  test('totalBytes 只统计合法记录', () async {
    expect(await store.totalBytes(), 0);
    await store.saveEpisode(episode(bytes: 4096));
    expect(await store.totalBytes(), 4096);
  });
}
