import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/cached_dramas_page.dart';
import 'package:fqapp/services/drama_download_store.dart';
import 'package:fqapp/services/drama_downloader.dart';
import 'package:fqapp/services/episode_source_cache.dart';

import 'support/fakes.dart';

void main() {
  late MemoryDramaDownloadStore store;
  late DramaDownloader downloader;

  setUp(() {
    store = MemoryDramaDownloadStore();
    downloader = DramaDownloader(store: store);
  });

  CachedEpisode seedEpisode(String itemId, {int index = 0}) {
    return CachedEpisode(
      seriesId: 'series1',
      itemId: itemId,
      title: '第${index + 1}集',
      index: index,
      keyHex: 'k',
      height: 1080,
      variantName: '1080P',
      bytes: 2048,
      filePath: '/tmp/unused.mp4',
      cachedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> seed() async {
    await store.ensureCatalogue(
      CachedDrama(
        id: 'series1',
        title: '测试剧',
        cover: '',
        episodes: [
          Chapter(itemId: 'ep0', title: '第一集', volumeName: ''),
          Chapter(itemId: 'ep1', title: '第二集', volumeName: ''),
        ],
      ),
    );
    await store.saveEpisode(seedEpisode('ep0'));
    await store.saveEpisode(seedEpisode('ep1', index: 1));
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: CachedDramasPage(store: store, downloader: downloader)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('按剧聚合展示：集数、占用、集级明细', (tester) async {
    await seed();
    await pumpPage(tester);

    expect(find.text('测试剧'), findsOneWidget);
    expect(find.byKey(const ValueKey('drama-card-series1')), findsOneWidget);
    expect(find.text('2 集 · 4.0 KB'), findsOneWidget);
    // 展开集级明细。
    await tester.tap(find.text('测试剧'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drama-episode-ep0')), findsOneWidget);
    expect(find.byKey(const ValueKey('drama-episode-ep1')), findsOneWidget);
  });

  testWidgets('删除单集走确认弹窗并刷新列表', (tester) async {
    await seed();
    await pumpPage(tester);
    await tester.tap(find.text('测试剧'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('drama-episode-delete-ep0')));
    await tester.pumpAndSettle();
    expect(find.text('删除这一集'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(await store.isDownloaded('ep0'), isFalse);
    expect(find.byKey(const ValueKey('drama-episode-ep0')), findsNothing);
    expect(find.byKey(const ValueKey('drama-episode-ep1')), findsOneWidget);
  });

  testWidgets('空态文案可见', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('暂无离线缓存'), findsOneWidget);
  });

  testWidgets('下载中任务以进度行出现在卡片之外', (tester) async {
    // 未完成集不进 store：任务快照直接来自下载引擎。
    final gate = Completer<EpisodeSource>();
    final downloader = DramaDownloader(
      store: store,
      // resolver 永不完成：任务停在排队/下载中，不触真网。
      resolve: (episode) => gate.future,
    );
    await downloader.enqueue(
      drama: CachedDrama(
        id: 'series1',
        title: '测试剧',
        cover: '',
        episodes: [Chapter(itemId: 'ep9', title: '第九集', volumeName: '')],
      ),
      episodes: [Chapter(itemId: 'ep9', title: '第九集', volumeName: '')],
    );
    await tester.pumpWidget(
      MaterialApp(home: CachedDramasPage(store: store, downloader: downloader)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('download-task-ep9')), findsOneWidget);
    // 任务在 resolver 里卡住：状态已是「下载中」（_pump 先置态再跑）。
    expect(find.text('下载中'), findsOneWidget);
  });

  testWidgets('删除整剧后回到空态：引擎不残留已完成任务行', (tester) async {
    // TestWidgetsFlutterBinding 把所有 HTTP 请求改成 400，真下载必须临时
    // TestWidgetsFlutterBinding 把所有 HTTP 请求改成 400，真下载必须临时
    // 摘掉这层 mock（HttpOverrides 只有 global setter，用 current 存旧值）。
    final savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = savedOverrides);
    // 页面既不给空态又显示幽灵任务行。真实 socket 只能在 runAsync 里跑。
    final drama = CachedDrama(
      id: 'series1',
      title: '测试剧',
      cover: '',
      episodes: [Chapter(itemId: 'ep0', title: '第一集', volumeName: '')],
    );
    late DramaDownloader real;
    await tester.runAsync(() async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final payload = Uint8List.fromList(List.generate(256, (i) => i % 256));
      server.listen((request) async {
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      real = DramaDownloader(
        store: store,
        resolve: (episode) async => EpisodeSource(
          'http://127.0.0.1:${server.port}/v.mp4',
          'k',
          const [],
        ),
      );
      await store.ensureCatalogue(drama);
      await real.enqueue(drama: drama, episodes: drama.episodes);
      for (var i = 0; i < 200 && !await store.isDownloaded('ep0'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(await store.isDownloaded('ep0'), isTrue);
    expect(real.value.single.status, DramaDownloadStatus.completed);

    await tester.pumpWidget(
      MaterialApp(home: CachedDramasPage(store: store, downloader: real)),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试剧'), findsOneWidget);

    await tester.tap(find.byTooltip('删除《测试剧》缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(await store.isDownloaded('ep0'), isFalse);
    expect(find.textContaining('暂无离线缓存'), findsOneWidget);
    expect(find.text('已完成'), findsNothing);
  });
}
