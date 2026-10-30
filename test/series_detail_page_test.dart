import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/home/home_design.dart' show HomePalette;

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('series-detail-test-');
    Hive.init(directory.path);
    await ShelfStore.instance.init();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() async => ShelfStore.instance.clear());

  testWidgets('头部按官方 a34 规格：标题 2 行内、状态行、分类 chips、无封面角标', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
    );
    expect(find.byKey(const ValueKey('series-detail-page')), findsOneWidget);
    // 顶栏（滚动态常驻，透明但仍在树里）与头部各一份。
    expect(find.text('抽象三国第一季'), findsNWidgets(2));
    // 实机取证：封面不带状态角标，状态走状态行与选集区头部。
    expect(
      find.byKey(const ValueKey('series-detail-cover-badge')),
      findsNothing,
    );
    // 状态行：官方 `bp` 布局 = episodeLabel「全12集」+ 播放量（实机无追更段）。
    expect(find.text('全12集 · 8.7万次播放'), findsOneWidget);
    // 分类 chips（官方 RecommendTagLayout）。
    expect(
      find.byKey(const ValueKey('series-detail-categories')),
      findsOneWidget,
    );
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('搞笑'), findsOneWidget);
  });

  testWidgets('tab 结构照实机：基本信息/剧评，无选集；有原著时出现原著小说', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
    );
    final tabs = find.byKey(const ValueKey('series-detail-tabs'));
    expect(
      find.descendant(of: tabs, matching: find.text('基本信息')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tabs, matching: find.text('剧评')),
      findsOneWidget,
    );
    // 官方 tab 没有「选集」（选集区在剧评与原著之间，无自己的 tab）。
    expect(find.descendant(of: tabs, matching: find.text('选集')), findsNothing);
    expect(
      find.descendant(of: tabs, matching: find.text('原著小说')),
      findsNothing,
    );

    // 有关联原著时出现第三个 tab，锚到原著小说区块。
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(
        originalBook: const SeriesRelateBook(
          id: 'book-1',
          title: '三国：他们的武将技不太对劲',
        ),
      ),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
    );
    final tabs2 = find.byKey(const ValueKey('series-detail-tabs'));
    expect(
      find.descendant(of: tabs2, matching: find.text('原著小说')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: tabs2, matching: find.text('原著小说')));
    await tester.pumpAndSettle();
    // 书区在列表底部，懒加载要先滚过去（区块未构建时锚点滚动无 context）。
    await scrollToWidget(tester, find.text('立即阅读'));
    expect(find.text('三国：他们的武将技不太对劲'), findsOneWidget);
    expect(find.text('立即阅读'), findsOneWidget);
  });

  testWidgets('选集区头部右侧带完结状态（实机：已完结 共105集 ›）', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
    );
    // 选集区在首屏之下（基本信息/剧评在前），懒加载列表要先滚过去。
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episode-status')),
    );
    final status = tester.widget<Text>(
      find.byKey(const ValueKey('series-episode-status')),
    );
    expect(status.data, '已完结 共12集');
    // 选集区块标题存在（无 tab，但区块在）。
    expect(find.text('选集'), findsWidgets);
  });

  testWidgets('选集格子状态与点击：当前集强调色描边、已看灰字、点击回传下标', (tester) async {
    final played = <int>[];
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
      startIndex: 3,
      watchedIds: {'ep-0', 'ep-1', 'ep-2'},
      onPlay: (index) => played.add(index),
    );
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episode-6')),
    );
    // 当前集（第 4 格）用强调色描边 + 淡强调底 + 强调色文字。
    final currentTile = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const ValueKey('series-episode-3')),
        matching: find.byType(Material),
      ),
    );
    final shape = currentTile.shape! as RoundedRectangleBorder;
    expect(shape.side.color, HomePalette.accent);
    expect(currentTile.color, HomePalette.accent.withValues(alpha: 0.08));
    final current = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('series-episode-3')),
        matching: find.text('4'),
      ),
    );
    expect(current.style?.color, HomePalette.accentStrong);
    expect(current.style?.fontWeight, FontWeight.bold);
    // 已看集（第 1 格）灰字 #706C66（浅色 palette.muted）。
    final watched = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('series-episode-0')),
        matching: find.text('1'),
      ),
    );
    expect(watched.style?.color, const Color(0xFF706C66));
    // 点普通格回传该集下标。
    await tester.tap(find.byKey(const ValueKey('series-episode-6')));
    expect(played, [6]);
  });

  testWidgets('播放钮在头部下方：续播文案照官方「继续播放」，点击回传当前下标', (tester) async {
    final played = <int>[];
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
      startIndex: 4,
      onPlay: (index) => played.add(index),
    );
    expect(find.byKey(const ValueKey('series-detail-actions')), findsOneWidget);
    // 本地详情页明确展示续播集数。
    expect(find.text('继续播放 · 第5集'), findsOneWidget);
    expect(find.text('继续播放 第5集'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('series-detail-play-button')));
    expect(played, [4]);
  });

  testWidgets('无进度时播放钮为「立即播放」', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
    );
    expect(find.text('立即播放'), findsOneWidget);
  });

  testWidgets('头部收藏钮写入本机书架并可取消', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
    );
    expect(
      find.byKey(const ValueKey('series-detail-fav-button')),
      findsOneWidget,
    );
    expect(find.text('收藏'), findsOneWidget);
    // 收藏走账号，本地占位：轻点出 SnackBar 提示（同 light more panel 先例）。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('series-detail-fav-button')));
      // Hive 的文件写入需要真实事件循环，不能依赖 fake async 的 pump。
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect((snackBar.content as Text).data, '已收藏到本机书架');
    expect(ShelfStore.instance.contains('video', 'series-1'), isTrue);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('series-detail-fav-button')));
      // Hive 的文件写入需要真实事件循环，不能依赖 fake async 的 pump。
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(ShelfStore.instance.contains('video', 'series-1'), isFalse);
  });

  testWidgets('移除不可用的评分与更多入口', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
      comments: commentsFixture(),
    );
    expect(find.byKey(const ValueKey('series-detail-rate-card')), findsNothing);
    expect(find.text('看5分钟参与评分'), findsNothing);
    expect(find.byKey(const ValueKey('series-detail-more')), findsNothing);
  });

  testWidgets('长简介折叠 3 行：灰色展开钮，点开展开全文并出现收起', (tester) async {
    const longIntro =
        '被公司开除的范理拒绝内耗，转身开起下午才营业的早餐店。凭真材实料和'
        '极致手艺，他把冷清侧门变成烟火聚场，也让邻里看见认真做事的人，终会被'
        '认可。可客流突然暴涨，神秘系统也在深夜亮起了面板，接下来他要面对的，'
        '是连锁品牌的挖角、供应商的刁难与一场突如其来的美食大赛。深夜的面板'
        '再次刷新，奖励从一笼小笼包升级到整套早餐车，也把麻烦一并送上了门：'
        '隔壁街的王记要搞买一送一，房东忽然要收回铺面，而系统任务倒计时只剩'
        '七天。范理决定不再一个人硬扛，他拉上早市上认识的老陈和夜班司机小'
        '林，把这份下午才营业的倔强，做成了整条街的早餐地图。';
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(intro: longIntro),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
    );
    // 折叠态：正文截断出「…」，右下角灰色「展开」（palette.muted）。
    final collapsed = tester.widget<Text>(
      find.byKey(const ValueKey('series-detail-intro')),
    );
    expect(collapsed.data, endsWith('…'));
    final expand = tester.widget<Text>(find.text('展开'));
    expect(expand.style?.color, const Color(0xFF706C66));
    // 展开后全文 + 「收起」。
    await tester.tap(find.byKey(const ValueKey('series-detail-intro')));
    await tester.pumpAndSettle();
    final expanded = tester.widget<Text>(
      find.byKey(const ValueKey('series-detail-intro')),
    );
    expect(expanded.data, longIntro);
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets('剧评区：头部计数 + 全部剧评入口 + 横滑卡片；锚点滚动可达', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
      comments: commentsFixture(),
    );
    // tab 行固定在顶栏下（官方 AppBarLayout 行为）；点「剧评」滚动锚点。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('series-detail-tabs')),
        matching: find.text('剧评'),
      ),
    );
    await tester.pumpAndSettle();
    // 头部：剧评 + 计数 + 右侧「全部剧评」（「剧评」另有 tab 一份）。
    expect(find.text('剧评'), findsOneWidget);
    expect(find.text('剧评 · 952'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('series-detail-comments-all')),
      findsOneWidget,
    );
    // 横滑卡片渲染两条评论。
    expect(find.text('这剧可以看'), findsOneWidget);
    expect(find.text('武将技不太对劲'), findsOneWidget);
    expect(find.text('期待你的第一条剧评'), findsNothing);
  });

  testWidgets('超过 50 集出现分段条，切段显示对应区间', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(episodeCount: 80),
      episodes: [for (var i = 0; i < 80; i++) chapterAt(i)],
    );
    await scrollToWidget(tester, find.text('1–50'));
    expect(find.byKey(const ValueKey('series-episode-pages')), findsOneWidget);
    expect(find.text('1–50'), findsOneWidget);
    expect(find.text('51–80'), findsOneWidget);
    // 第二段当前不可见：第 51 格不在树里。
    expect(find.byKey(const ValueKey('series-episode-50')), findsNothing);
    await tester.tap(find.text('51–80'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('series-episode-50')), findsOneWidget);
    expect(find.text('51'), findsOneWidget);
  });

  testWidgets('顶栏返回键 pop 页面', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => SeriesDetailPage(
                  seriesId: 'series-1',
                  historyStore: MemoryReaderStore(),
                  title: '抽象三国第一季',
                  cover: '',
                  episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
                  seriesLoader: (_) async => seriesDetailFixture(),
                  commentLoader: (_) async => const PlayletCommentPage(),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('series-detail-page')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('series-detail-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('series-detail-page')), findsNothing);
  });

  testWidgets('异步目录按稳定 ID 恢复续播并定位第 51-100 集', (tester) async {
    final directory = Completer<List<List<Chapter>>>();
    final store = MemoryReaderStore(
      entry: {'episodeId': 'ep-95', 'episode': 2, 'position': 20.0},
    );
    store.watched['series-1'] = {'ep-95'};
    int? played;
    List<Chapter>? selectedEpisodes;
    await tester.pumpWidget(
      hostPage(
        SeriesDetailPage(
          seriesId: 'series-1',
          historyStore: store,
          initialDetail: seriesDetailFixture(episodeCount: 120),
          directoryLoader: (_) => directory.future,
          commentLoader: (_) async => const PlayletCommentPage(),
          onPlaySelection: (index, episodes, _) {
            played = index;
            selectedEpisodes = episodes;
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('加载中…'), findsOneWidget);
    final episodes = [for (var i = 0; i < 120; i++) chapterAt(i)];
    directory.complete([episodes]);
    await tester.pumpAndSettle();
    expect(find.text('继续播放 · 第96集'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('series-detail-play-button')));
    expect(played, 95);
    expect(selectedEpisodes, episodes);
    // 当前集在第 2 段（51–100），分段条跟到当前段。
    expect(find.text('51–100').hitTestable(), findsOneWidget);
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episode-95')),
    );
    expect(find.byKey(const ValueKey('series-episode-0')), findsNothing);
  });

  testWidgets('第一集有历史也显示续播，宿主显式当前集优先于历史', (tester) async {
    final store = MemoryReaderStore(
      entry: {'episodeId': 'ep-0', 'position': 25},
    );
    for (final explicitIndex in <int?>[null, 2]) {
      await tester.pumpWidget(
        hostPage(
          SeriesDetailPage(
            key: UniqueKey(),
            seriesId: 'series-1',
            historyStore: store,
            initialDetail: seriesDetailFixture(),
            startIndex: explicitIndex,
            episodes: [for (var i = 0; i < 3; i++) chapterAt(i)],
            commentLoader: (_) async => const PlayletCommentPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('继续播放 · 第${explicitIndex == null ? 1 : 3}集'),
        findsOneWidget,
      );
    }
  });

  testWidgets('不可播集禁止触摸和语义点击，底部按钮禁用', (tester) async {
    var played = false;
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [chapterAt(0, disabled: true)],
      onPlay: (_) => played = true,
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('series-detail-play-button')),
    );
    expect(button.onPressed, isNull);
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episode-0')),
    );
    final tile = tester.widget<Semantics>(
      find.byKey(const ValueKey('series-episode-0')),
    );
    expect(tile.properties.enabled, isFalse);
    expect(tile.properties.onTap, isNull);
    await tester.tap(find.byKey(const ValueKey('series-episode-0')));
    expect(played, isFalse);
  });

  testWidgets('目录失败只在选集区重试，播放钮不变成「重试加载」', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      hostPage(
        SeriesDetailPage(
          seriesId: 'series-1',
          historyStore: MemoryReaderStore(),
          initialDetail: seriesDetailFixture(),
          directoryLoader: (_) async {
            if (++calls == 1) throw StateError('offline');
            return [
              [chapterAt(0)],
            ];
          },
          commentLoader: (_) async => const PlayletCommentPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 重试只在选集区出现一次；播放钮保持不可播文案。
    expect(find.text('重试加载'), findsOneWidget);
    expect(find.byKey(const ValueKey('series-episodes-retry')), findsOneWidget);
    expect(find.text('暂不可播放'), findsOneWidget);
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episodes-retry')),
    );
    await tester.tap(find.byKey(const ValueKey('series-episodes-retry')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('重试加载'), findsNothing);
    expect(find.text('立即播放'), findsOneWidget);
  });

  testWidgets('详情与剧评分别重试，不重复加载成功的目录', (tester) async {
    var detailCalls = 0;
    var commentCalls = 0;
    var directoryCalls = 0;
    await tester.pumpWidget(
      hostPage(
        SeriesDetailPage(
          seriesId: 'series-1',
          title: '兜底标题',
          historyStore: MemoryReaderStore(),
          seriesLoader: (_) async {
            if (++detailCalls == 1) throw StateError('offline');
            return seriesDetailFixture();
          },
          directoryLoader: (_) async {
            directoryCalls++;
            return [
              [chapterAt(0)],
            ];
          },
          commentLoader: (_) async {
            if (++commentCalls == 1) throw StateError('offline');
            return commentsFixture();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('详情加载失败'), findsOneWidget);
    await scrollToWidget(tester, find.text('详情加载失败'));
    await tester.tap(find.text('重试').first);
    await tester.pumpAndSettle();
    expect(detailCalls, 2);
    expect(find.text('详情加载失败'), findsNothing);
    await scrollToWidget(tester, find.text('剧评加载失败'));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(commentCalls, 2);
    expect(directoryCalls, 1);
    expect(find.text('剧评加载失败'), findsNothing);
  });

  testWidgets('已有详情不重复请求，晚到响应不更新已销毁页面', (tester) async {
    final comments = Completer<PlayletCommentPage>();
    var calls = 0;
    await tester.pumpWidget(
      hostPage(
        SeriesDetailPage(
          seriesId: 'series-1',
          initialDetail: seriesDetailFixture(),
          episodes: [chapterAt(0)],
          historyStore: MemoryReaderStore(),
          seriesLoader: (_) async {
            calls++;
            return seriesDetailFixture();
          },
          commentLoader: (_) => comments.future,
        ),
      ),
    );
    await tester.pump();
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    comments.complete(commentsFixture());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字体与安全区：选集可达，内容没有溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(1.8),
            padding: const EdgeInsets.only(top: 32, bottom: 24),
          ),
          child: child!,
        ),
        home: SeriesDetailPage(
          seriesId: 'series-1',
          historyStore: MemoryReaderStore(),
          initialDetail: seriesDetailFixture(
            intro: '长简介包含表情👨‍👩‍👧‍👦，验证文字折叠和展开。' * 20,
            originalBook: const SeriesRelateBook(id: 'b1', title: '很长的原著小说书名'),
          ),
          episodes: [for (var i = 0; i < 90; i++) chapterAt(i)],
          commentLoader: (_) async => commentsFixture(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 选集就在首屏播放钮下方，滚过去不会溢出。
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episode-0')),
    );
    expect(
      find.byKey(const ValueKey('series-episode-0')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await scrollToWidget(tester, find.text('立即阅读'));
    expect(tester.takeException(), isNull);
  });
  testWidgets('长剧当前分段自动露出，横向定位不挪动详情锚点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(episodeCount: 300),
      episodes: [for (var i = 0; i < 300; i++) chapterAt(i)],
      startIndex: 245,
    );
    // 当前集落在第 5 段（201–250），首屏的分段条自动横向滚到它。
    expect(find.text('201–250').hitTestable(), findsOneWidget);
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episode-245')),
    );
    expect(
      find.byKey(const ValueKey('series-episode-240')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('背景铺满宽度：顶部淡色带平滑淡出，返回栏与吸顶导航没有异色横条', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: const EdgeInsets.only(top: 32)),
            child: child!,
          ),
          home: SeriesDetailPage(
            seriesId: 'series-1',
            historyStore: MemoryReaderStore(),
            initialDetail: seriesDetailFixture(seriesColorHex: '#302010'),
            episodes: [for (var i = 0; i < 90; i++) chapterAt(i)],
            commentLoader: (_) async => commentsFixture(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bandTop = Color.alphaBlend(
      const Color(0xFF302010).withValues(alpha: 0.10),
      const Color(0xFFF6F6F6),
    );
    Future<void> checkPixels() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final pixels = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
      });
      expect(pixels, isNotNull);
      int channel(int x, int y, int c) =>
          pixels!.getUint8((y * 360 + x) * 4 + c);
      // 右边缘没有文字/封面：同时覆盖状态栏、返回栏上下边界、tab 和色带尾部。
      expect(channel(358, 0, 0), closeTo(bandTop.r * 255, 2));
      expect(channel(358, 300, 0), closeTo(0xF6, 2));
      // 相邻行不跳变：顶栏与吸顶 tab 的边界都不能出现横条。
      for (var y = 1; y < 420; y++) {
        expect(
          (channel(358, y, 0) - channel(358, y - 1, 0)).abs(),
          lessThanOrEqualTo(3),
          reason: 'y=$y',
        );
      }
    }

    await checkPixels();
    final scroll = tester.widget<CustomScrollView>(
      find.byKey(const ValueKey('series-detail-content')),
    );
    scroll.controller!.jumpTo(350);
    await tester.pumpAndSettle();
    await checkPixels();
    expect(tester.takeException(), isNull);
  });
}
