import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/drama_download_sheet.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/drama_cache_preferences.dart';
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
    int currentIndex = 0,
    ThemeData? theme,
    DramaDownloader? engine,
    List<EpisodeVariant> qualities = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: DramaDownloadSheet(
            seriesId: 'series1',
            title: '测试剧',
            cover: '',
            episodes: episodes(episodeCount),
            currentIndex: currentIndex,
            qualities: qualities,
            downloader: engine ?? downloader,
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
    SharedPreferences.setMockInitialValues({});
    DramaCachePreferences.instance.resetForTest();
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

  testWidgets('深色下集数格用浅色字与浮层底', (tester) async {
    await pumpSheet(tester, theme: AppTheme.createTheme(Brightness.dark));

    // 弹层标题和未选中的集数格以前硬编码为纯黑字/6% 黑底，深色下看不见。
    expect(
      tester.widget<Text>(find.text('离线缓存 · 测试剧')).style?.color,
      const Color(0xFFF5F1EB),
    );
    expect(
      tester.widget<Text>(find.text('第 1 集')).style?.color,
      const Color(0xFFF5F1EB),
    );
    final cell = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const ValueKey('download-cell-ep0')),
        matching: find.byType(Container),
      ),
    );
    expect((cell.decoration! as BoxDecoration).color, const Color(0xFF202023));
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

  testWidgets('「往后 N 集」从当前集往后入队，不是从第 1 集', (tester) async {
    // resolver 永不完成：任务停在下载中，不触真网。
    final engine = DramaDownloader(
      store: store,
      resolve: (episode) => Completer<EpisodeSource>().future,
    );
    await pumpSheet(tester, episodeCount: 9, currentIndex: 2, engine: engine);

    // 起点是正在看的第 3 集之后；剩余 6 集时给 3/5/剩余 三档。
    expect(find.byKey(const ValueKey('download-ahead-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-ahead-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-ahead-6')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('download-ahead-3')));
    await tester.pumpAndSettle();

    expect(
      engine.value.map((task) => task.itemId).toList(),
      ['ep3', 'ep4', 'ep5'],
      reason: '只从当前集往后取 3 集，且都是自动缓存之外的手动任务',
    );
    expect(engine.value.every((task) => !task.auto), isTrue);
  });

  testWidgets('打开面板就落在正在看的那一集的区间', (tester) async {
    await pumpSheet(tester, episodeCount: 90, currentIndex: 35);
    final chip = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('download-group-1')),
    );
    expect(chip.selected, isTrue, reason: '第 36 集属于 31-60 这一段');
    expect(find.text('第 36 集'), findsOneWidget);
  });

  testWidgets('一千集时改用下拉分段，直接落在正在看的那一段', (tester) async {
    // 30 集一段 → 34 段。铺成一行 chip 会是一条几千像素的长条，选中项还
    // 可能滚在屏幕外；改下拉后任何集数都能直接定位。
    await pumpSheet(tester, episodeCount: 1000, currentIndex: 700);

    expect(find.byKey(const ValueKey('download-group-picker')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('download-group-0')),
      findsNothing,
      reason: '段数多时不再铺 chip',
    );
    expect(find.text('第 691-720 集 / 共 1000 集'), findsOneWidget);
    // 第 700 集在 691-720 段的倒数第五个，打开时要自动滚进视野。
    expect(find.text('第 700 集'), findsOneWidget, reason: '当前集要滚进视野');
    expect(find.text('第 800 集'), findsNothing, reason: '不该显示别的段');
  });

  testWidgets('上一段/下一段切换后网格从该段第一集开始', (tester) async {
    await pumpSheet(tester, episodeCount: 1000, currentIndex: 700);

    await tester.tap(find.byKey(const ValueKey('download-group-next')));
    await tester.pumpAndSettle();

    expect(find.text('第 721-750 集 / 共 1000 集'), findsOneWidget);
    expect(find.text('第 721 集'), findsOneWidget);
    expect(find.text('第 691 集'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('download-group-prev')));
    await tester.pumpAndSettle();
    expect(find.text('第 691 集'), findsOneWidget);
  });

  testWidgets('网格滚动后切换分段，不会停在上一段的滚动位置', (tester) async {
    // 真机上出现过「1-30 集」标签下第一行却是「第 9 集」：GridView 复用
    // 了上一个分段的滚动位置。
    await pumpSheet(tester, episodeCount: 1000, currentIndex: 0);

    final grid = find.byKey(const ValueKey('download-grid-0'));
    expect(grid, findsOneWidget);
    await tester.drag(grid, const Offset(0, -160));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('download-group-next')));
    await tester.pumpAndSettle();

    // 新分段的网格是新建的（key 变了），滚动位置归零。
    expect(find.byKey(const ValueKey('download-grid-1')), findsOneWidget);
    expect(find.text('第 31 集'), findsOneWidget);
    final scrollable = tester.widget<GridView>(
      find.byKey(const ValueKey('download-grid-1')),
    );
    expect(scrollable.childrenDelegate.estimatedChildCount, 30);
  });

  testWidgets('窄屏（360dp）下自动缓存行与快捷 chip 不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpSheet(tester, episodeCount: 9, currentIndex: 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('画质只列这部剧真实给到的档位', (tester) async {
    await pumpSheet(
      tester,
      episodeCount: 3,
      qualities: const [
        EpisodeVariant(name: '1080P', url: 'u1080', keyHex: '', height: 1080),
        EpisodeVariant(name: '360P', url: 'u360', keyHex: '', height: 360),
      ],
    );

    expect(find.byKey(const ValueKey('download-quality-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-quality-1080')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-quality-360')), findsOneWidget);
    // 上游没给 720，就不该让用户选 720。
    expect(find.byKey(const ValueKey('download-quality-720')), findsNothing);
  });

  testWidgets('选 720P 后下载任务带上画质上限', (tester) async {
    final engine = DramaDownloader(
      store: store,
      resolve: (episode) => Completer<EpisodeSource>().future,
    );
    await pumpSheet(tester, episodeCount: 3, engine: engine);

    expect(find.text('画质'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('download-quality-720')));
    await tester.pumpAndSettle();
    expect(DramaCachePreferences.instance.downloadHeight.value, 720);

    await tester.tap(find.byKey(const ValueKey('download-cell-ep0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download-confirm')));
    await tester.pumpAndSettle();

    expect(engine.value.single.maxHeight, 720);
  });

  testWidgets('存的上限不在本剧档位里时，高亮实际会取的那一档', (tester) async {
    const qualities = [
      EpisodeVariant(name: '1080P', url: 'u1080', keyHex: '', height: 1080),
      EpisodeVariant(name: '360P', url: 'u360', keyHex: '', height: 360),
    ];
    ChoiceChip chip(String height) => tester.widget<ChoiceChip>(
      find.byKey(ValueKey('download-quality-$height')),
    );

    // 上一部选了 720，这部剧只有 1080/360：下载器取「不超过上限的最高一档」
    // = 360。高亮必须跟着这个结果，否则一个 chip 都不选中，用户以为没设上。
    await DramaCachePreferences.instance.setDownloadHeight(720);
    await pumpSheet(tester, episodeCount: 3, qualities: qualities);
    expect(chip('360').selected, isTrue, reason: '720 不在档位里，实际会下 360');
    expect(chip('1080').selected, isFalse);
    expect(chip('0').selected, isFalse, reason: '「最高」不等于「有上限」');

    // 上限比所有档位都低：退到最小一档，同样要看得出来。
    await DramaCachePreferences.instance.setDownloadHeight(240);
    await pumpSheet(tester, episodeCount: 3, qualities: qualities);
    expect(chip('360').selected, isTrue);
    expect(chip('1080').selected, isFalse);
  });

  testWidgets('边看边缓存默认 5 集，关掉后写回偏好', (tester) async {
    await pumpSheet(tester, episodeCount: 8, currentIndex: 1);
    final prefs = DramaCachePreferences.instance;
    expect(prefs.ahead.value, DramaCachePreferences.defaultAhead);
    expect(find.text('边看边缓存'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('download-auto-cache-switch')));
    await tester.pumpAndSettle();

    expect(prefs.ahead.value, 0);
    expect(find.text('已关闭，手动缓存不受影响'), findsOneWidget);
  });
}
