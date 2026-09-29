import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/drama_download_sheet.dart';
import 'package:fqapp/services/drama_download_store.dart';
import 'package:fqapp/services/drama_downloader.dart';
import 'package:fqapp/services/episode_source_cache.dart';

import 'support/fakes.dart';

void main() {
  late MemoryDramaDownloadStore store;
  late DramaDownloader downloader;

  List<Chapter> episodes(int count) => [
    for (var i = 0; i < count; i++)
      Chapter(itemId: 'ep$i', title: '第${i + 1}集', volumeName: ''),
  ];

  Future<void> pumpSheet(
    WidgetTester tester, {
    int episodeCount = 3,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DramaDownloadSheet(
            seriesId: 'series1',
            title: '测试剧',
            cover: '',
            episodes: episodes(episodeCount),
            downloader: downloader,
            store: store,
            // 测试宿主没有 connectivity 平台通道：直接给「WiFi 在线」。
            connectivityProbe: () async => (online: true, metered: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    store = MemoryDramaDownloadStore();
    downloader = DramaDownloader(store: store);
  });

  testWidgets('网格渲染集数，已缓存集置灰为「已缓存」且不可选', (tester) async {
    await store.saveEpisode(
      CachedEpisode(
        seriesId: 'series1',
        itemId: 'ep0',
        title: '第一集',
        index: 0,
        keyHex: 'k',
        height: 1080,
        variantName: '1080P',
        bytes: 1,
        filePath: '/tmp/x.mp4',
        cachedAt: 0,
      ),
    );
    await pumpSheet(tester, episodeCount: 3);

    expect(find.text('已缓存'), findsOneWidget);
    expect(find.text('第 2 集'), findsOneWidget);
    // 已缓存集不在待选集中：全选只选中剩余 2 集。
    await tester.tap(find.byKey(const ValueKey('download-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('下载 (2)'), findsOneWidget);
  });

  testWidgets('点选集 → 下载按钮入队，任务态实时显示', (tester) async {
    // resolver 永不完成：任务停在下载中，不触真网。
    final downloader = DramaDownloader(
      store: store,
      resolve: (episode) => Completer<EpisodeSource>().future,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DramaDownloadSheet(
            seriesId: 'series1',
            title: '测试剧',
            cover: '',
            episodes: episodes(2),
            downloader: downloader,
            store: store,
            connectivityProbe: () async => (online: true, metered: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('download-cell-ep0')));
    await tester.pumpAndSettle();
    expect(find.text('下载 (1)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('download-confirm')));
    await tester.pumpAndSettle();

    // 选中集清空，任务行出现且不在可选态（resolver 未完成=下载中）。
    expect(find.text('下载 (0)'), findsOneWidget);
    expect(find.text('下载中'), findsOneWidget);
    expect(downloader.value.single.itemId, 'ep0');
  });

  testWidgets('全选/取消全选在当前组内翻转', (tester) async {
    await pumpSheet(tester, episodeCount: 3);
    await tester.tap(find.byKey(const ValueKey('download-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('下载 (3)'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('download-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('下载 (0)'), findsOneWidget);
  });
}
