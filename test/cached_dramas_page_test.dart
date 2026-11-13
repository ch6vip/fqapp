import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/cached_dramas_page.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/drama_download_store.dart';
import 'package:fqapp/services/drama_downloader.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/services/platform_capabilities.dart';
import 'package:fqapp/widgets/cache/cache_page_widgets.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

void main() {
  late MemoryDramaDownloadStore store;
  late DramaDownloader downloader;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  Future<void> seedManyDramas() async {
    for (var index = 0; index < 40; index++) {
      final seriesId = 'series$index';
      final episodeId = 'ep$index';
      await store.ensureCatalogue(
        CachedDrama(
          id: seriesId,
          title: 'Drama ${index + 1}',
          cover: '',
          episodes: [Chapter(itemId: episodeId, title: '第1集', volumeName: '')],
        ),
      );
      await store.saveEpisode(
        CachedEpisode(
          seriesId: seriesId,
          itemId: episodeId,
          title: '第1集',
          index: 0,
          keyHex: 'k',
          height: 1080,
          variantName: '1080P',
          bytes: 2048,
          filePath: '/tmp/unused.mp4',
          cachedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CachedDramasPage(store: store, downloader: downloader),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<AppThemeStyleStore> pumpDramaCacheWithStyle(
    WidgetTester tester, {
    required bool classic,
  }) async {
    final styleStore = AppThemeStyleStore()
      ..value = classic ? AppThemeStyle.classic : AppThemeStyle.archive;
    addTearDown(styleStore.dispose);
    await tester.pumpWidget(
      AppUiHost(
        store: styleStore,
        home: CachedDramasPage(store: store, downloader: downloader),
      ),
    );
    await tester.pumpAndSettle();
    return styleStore;
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

  for (final classic in [false, true]) {
    testWidgets(
      '经典=$classic：删除单集走确认弹窗并刷新列表',
      (tester) async {
        await seed();
        await pumpDramaCacheWithStyle(tester, classic: classic);
        expect(find.text('测试剧'), findsOneWidget);
        if (!supportsVideoPlayback) {
          expect(find.textContaining('加密离线播放'), findsNothing);
        }
        await tester.tap(find.text('测试剧'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey('drama-episode-delete-ep0')),
        );
        await tester.pumpAndSettle();
        expect(find.text('删除这一集'), findsOneWidget);
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();

        expect(await store.isDownloaded('ep0'), isFalse);
        expect(find.byKey(const ValueKey('drama-episode-ep0')), findsNothing);
        expect(find.byKey(const ValueKey('drama-episode-ep1')), findsOneWidget);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.linux,
      }),
    );
  }

  testWidgets('缓存页标题与设置入口使用同一名称', (tester) async {
    await pumpPage(tester);
    expect(find.byType(ArchiveFeaturePage), findsOneWidget);
    expect(find.text('短剧离线缓存'), findsOneWidget);
    expect(find.byType(ArchiveSection), findsOneWidget);
    expect(find.byType(SettingsSectionHeader), findsNothing);
  });

  for (final platform in TargetPlatform.values) {
    for (final classic in [false, true]) {
      testWidgets('$platform 经典=$classic：空态引导符合平台能力', (tester) async {
        await pumpDramaCacheWithStyle(tester, classic: classic);

        expect(find.textContaining('暂无离线缓存'), findsOneWidget);
        if (!supportsVideoPlayback) {
          expect(
            find.text('当前平台暂不支持视频播放，可在此查看和删除已有缓存；缓存不会被自动清理。'),
            findsOneWidget,
          );
          expect(find.textContaining('更多 → 离线缓存'), findsNothing);
          expect(find.textContaining('加密离线播放'), findsNothing);
        } else {
          expect(
            find.text('播放页「更多 → 离线缓存」选择想下载的集；下载的内容不会被自动清理。'),
            findsOneWidget,
          );
        }
      }, variant: TargetPlatformVariant({platform}));
    }
  }

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
      MaterialApp(
        home: CachedDramasPage(store: store, downloader: downloader),
      ),
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
      MaterialApp(
        home: CachedDramasPage(store: store, downloader: real),
      ),
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

  testWidgets('经典主题恢复缓存统计、设置卡列表与 AppBar 管理动作', (tester) async {
    await seed();
    await pumpDramaCacheWithStyle(tester, classic: true);

    expect(find.byType(ClassicFeaturePage), findsOneWidget);
    expect(find.byType(ArchiveFeaturePage), findsNothing);
    expect(find.byType(CacheSummaryCard), findsOneWidget);
    expect(find.text('已缓存 1 部 · 共 2 集'), findsOneWidget);
    expect(
      find.text(supportsVideoPlayback ? '占用空间：4.0 KB · 加密离线播放' : '占用空间：4.0 KB'),
      findsOneWidget,
    );
    expect(find.byType(ArchiveSection), findsNothing);
    expect(find.byKey(const ValueKey('dramas-more-actions')), findsNothing);
    expect(find.byKey(const ValueKey('dramas-pause-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('dramas-resume-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('dramas-clear-all')), findsOneWidget);
    // 没有在途任务时暂停/继续禁用，清空可用。
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('dramas-pause-all')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('dramas-clear-all')))
          .onPressed,
      isNotNull,
    );
  }, variant: TargetPlatformVariant(TargetPlatform.values.toSet()));

  testWidgets('经典 AppBar 清空全部仍走确认并刷新空态', (tester) async {
    await seed();
    await pumpDramaCacheWithStyle(tester, classic: true);

    await tester.tap(find.byKey(const ValueKey('dramas-clear-all')));
    await tester.pumpAndSettle();
    expect(find.text('清空全部离线缓存'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(await store.isDownloaded('ep0'), isFalse);
    expect(find.byType(CacheEmptyState), findsOneWidget);
    expect(find.textContaining('暂无离线缓存'), findsOneWidget);
  });

  testWidgets('切换主题保留展开的剧集与页面 State', (tester) async {
    await seed();
    final store = await pumpDramaCacheWithStyle(tester, classic: false);
    await tester.tap(find.text('测试剧'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('drama-episode-ep0')), findsOneWidget);
    final state = tester.state(find.byType(CachedDramasPage));

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();

    expect(find.byType(ClassicFeaturePage), findsOneWidget);
    expect(find.byType(ArchiveFeaturePage), findsNothing);
    expect(tester.state(find.byType(CachedDramasPage)), same(state));
    expect(find.byKey(const ValueKey('drama-episode-ep0')), findsOneWidget);

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();

    expect(find.byType(ArchiveFeaturePage), findsOneWidget);
    expect(tester.state(find.byType(CachedDramasPage)), same(state));
    expect(find.byKey(const ValueKey('drama-episode-ep0')), findsOneWidget);
  });

  testWidgets('集号未知的集记录在两套主题下都不冒充第 1 集', (tester) async {
    await store.ensureCatalogue(
      CachedDrama(
        id: 'series1',
        title: '测试剧',
        cover: '',
        episodes: [
          Chapter(
            itemId: 'ep0',
            title: '',
            volumeName: '剧集',
            hasKnownIndex: false,
          ),
        ],
      ),
    );
    await store.saveEpisode(seedEpisode('ep0', index: 4));
    final storeController = await pumpDramaCacheWithStyle(
      tester,
      classic: false,
    );
    await tester.tap(find.text('测试剧'));
    await tester.pumpAndSettle();

    expect(find.textContaining('集号未知'), findsOneWidget);
    expect(find.textContaining('第 1 集'), findsNothing);

    await storeController.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(find.textContaining('集号未知'), findsOneWidget);
    expect(find.textContaining('第 1 集'), findsNothing);
  });

  testWidgets('经典主题的暂停任务可继续下载', (tester) async {
    final gate = Completer<EpisodeSource>();
    final pendingDownloader = _CountingDownloader(
      store: store,
      // resolver 永不完成：任务停在暂停/续下状态，不触真网。
      resolve: (episode) => gate.future,
    );
    final drama = CachedDrama(
      id: 'series1',
      title: '测试剧',
      cover: '',
      episodes: [Chapter(itemId: 'ep9', title: '第九集', volumeName: '')],
    );
    await pendingDownloader.enqueue(drama: drama, episodes: drama.episodes);
    pendingDownloader.pauseAll();

    final storeController = AppThemeStyleStore()..value = AppThemeStyle.classic;
    addTearDown(storeController.dispose);
    await tester.pumpWidget(
      AppUiHost(
        store: storeController,
        home: CachedDramasPage(store: store, downloader: pendingDownloader),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('download-task-ep9')), findsOneWidget);
    expect(find.byTooltip('继续下载'), findsOneWidget);
    expect(pendingDownloader.value.single.status, DramaDownloadStatus.paused);

    // 主题切换只恢复内容锚点，不能把暂停任务重新入队。
    await storeController.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(pendingDownloader.value.single.status, DramaDownloadStatus.paused);
    expect(pendingDownloader.resumes, 0);
    await storeController.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(pendingDownloader.value.single.status, DramaDownloadStatus.paused);
    expect(pendingDownloader.resumes, 0);

    await tester.tap(find.byTooltip('继续下载'));
    await tester.pump();

    expect(
      pendingDownloader.value.single.status,
      isNot(DramaDownloadStatus.paused),
    );
    expect(pendingDownloader.resumes, 1);
  });

  testWidgets('40 部缓存：双向切主题按剧 ID 与行内偏移恢复，展开卡片保留', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedManyDramas();
    final styleStore = await pumpDramaCacheWithStyle(tester, classic: false);

    final list = find.byKey(const ValueKey('cached-dramas-scroll'));
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(1300);
    await tester.pump();

    final mid = _firstVisibleDrama(tester, list);
    expect(mid, isNotNull);
    final midIndex = int.parse(mid!.id.substring('series'.length));
    await tester.tap(find.text('Drama ${midIndex + 1}'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('drama-episode-ep$midIndex')), findsOneWidget);
    final expandedBefore = _firstVisibleDrama(tester, list);
    await styleStore.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();

    expect(find.byType(ClassicFeaturePage), findsOneWidget);
    expect(find.byType(CachedDramasPage), findsOneWidget);
    final expandedAfter = _firstVisibleDrama(tester, list);
    expect(expandedAfter, isNotNull);
    expect(expandedAfter!.id, expandedBefore!.id);
    expect(expandedAfter.offset, closeTo(expandedBefore.offset, 1.0));

    // 尾部：第 31 部仍有足够行垫底，回到档案主题时保持同一行内偏移。
    final tailRow = find.byKey(const ValueKey('cached-drama-row-series30'));
    await tester.scrollUntilVisible(tailRow, 260, scrollable: scrollable);
    await tester.ensureVisible(tailRow);
    await tester.pump();
    final tail = _firstVisibleDrama(tester, list);
    await styleStore.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();

    expect(find.byType(ArchiveFeaturePage), findsOneWidget);
    final tailAfter = _firstVisibleDrama(tester, list);
    expect(tailAfter, isNotNull);
    expect(tailAfter!.id, tail!.id);
    expect(tailAfter.offset, closeTo(tail.offset, 1.0));
  });
}

({String id, double offset})? _firstVisibleDrama(
  WidgetTester tester,
  Finder list,
) {
  final viewport = tester.getRect(list);
  final contentTop = viewport.top + kToolbarHeight;
  for (var index = 0; index < 40; index++) {
    final finder = find.text('Drama ${index + 1}');
    if (finder.evaluate().isEmpty) continue;
    final rect = tester.getRect(finder);
    if (rect.bottom <= contentTop + 0.5) continue;
    if (rect.top < contentTop - 0.5) continue;
    if (rect.bottom > viewport.bottom + 0.5) continue;
    return (id: 'series$index', offset: contentTop - rect.top);
  }
  return null;
}

class _CountingDownloader extends DramaDownloader {
  _CountingDownloader({required super.store, super.resolve});

  int resumes = 0;

  @override
  void resume(String itemId) {
    resumes++;
    super.resume(itemId);
  }
}
