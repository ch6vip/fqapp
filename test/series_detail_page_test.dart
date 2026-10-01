import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:hive/hive.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'support/fakes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/widgets/player/story_player_panel.dart' show SeriesStatus;

Chapter _chapter(int index, {bool disabled = false}) => Chapter(
  itemId: 'ep-$index',
  title: '第${index + 1}集',
  volumeName: '',
  disabled: disabled,
);

SeriesDetail _detail({
  int? status = SeriesStatus.finished,
  int episodeCount = 12,
  String episodeLabel = '全12集',
  SeriesRelateBook? originalBook,
  String seriesColorHex = '#F5E6C8',
  String intro = '这是一段剧集简介，用于基本信息区块的展开收起验证。',
}) => SeriesDetail(
  seriesId: 'series-1',
  title: '抽象三国第一季',
  intro: intro,
  cover: '',
  cast: const [
    CastMember(id: 'c1', actor: '张三', role: '刘备'),
    CastMember(id: 'c2', actor: '李四', role: '张飞'),
  ],
  episodeCount: episodeCount,
  episodeLabel: episodeLabel,
  playCount: 87000,
  followerCount: 1200,
  commentCount: 0,
  categories: const ['历史', '搞笑'],
  originalBook: originalBook,
  status: status,
  seriesColorHex: seriesColorHex,
);

PlayletCommentPage _comments() => const PlayletCommentPage(
  comments: [
    PlayletComment(id: 'm1', text: '这剧可以看', userName: '观众甲', diggCount: 22000),
    PlayletComment(id: 'm2', text: '武将技不太对劲', userName: '观众乙', diggCount: 5575),
  ],
  totalCount: 952,
);

Widget _host(Widget child) => MaterialApp(home: child);

Future<void> _pump(
  WidgetTester tester, {
  required SeriesDetail detail,
  required List<Chapter> episodes,
  int startIndex = 0,
  Set<String> watchedIds = const {},
  PlayletCommentPage? comments,
  ValueChanged<int>? onPlay,
}) async {
  await tester.pumpWidget(
    // 唯一 key 强制重建 State：同一测试里二次 pump 换 detail 时，
    // 同类型页面会被 Element 复用（initState/loader 不会重跑）。
    _host(
      KeyedSubtree(
        key: UniqueKey(),
        child: SeriesDetailPage(
          seriesId: 'series-1',
          historyStore: MemoryReaderStore(),
          title: detail.title,
          cover: detail.cover,
          episodes: episodes,
          startIndex: startIndex,
          watchedIds: watchedIds,
          seriesLoader: (_) async => detail,
          commentLoader: comments == null
              ? (_) async => const PlayletCommentPage()
              : (_) async => comments,
          // null 时走页面默认「推新播放器」；此时当前集 lottie 角标静止，
          // 宿主接线（onPlay 传入）才视为播放中——与真机语义一致。
          onPlayEpisode: onPlay,
        ),
      ),
    ),
  );
  // 宿主接线用例里当前集 lottie 会循环动画，pumpAndSettle 永不收敛，
  // 统一用固定步进 pump 等布局与惯性滚动落地。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// 把内容滚到目标组件可见（选集/原著等区块在首屏之下）；[extra] 再额外
/// 上移（贴底、会被底栏盖住的目标用）。
Future<void> _scrollTo(
  WidgetTester tester,
  Finder finder, {
  double extra = 0,
}) async {
  await tester.dragUntilVisible(
    finder,
    find.byKey(const ValueKey('series-detail-content')),
    const Offset(0, -160),
  );
  if (extra != 0) {
    await tester.drag(
      find.byKey(const ValueKey('series-detail-content')),
      Offset(0, -extra),
    );
  }
  // 拖拽末端的惯性滚动需要落地，步进 pump 而不是 pumpAndSettle
  // （宿主接线用例的播放中 lottie 循环动画永不收敛）。
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

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
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
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
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
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
    await _pump(
      tester,
      detail: _detail(
        originalBook: const SeriesRelateBook(
          id: 'book-1',
          title: '三国：他们的武将技不太对劲',
        ),
      ),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
    );
    final tabs2 = find.byKey(const ValueKey('series-detail-tabs'));
    expect(
      find.descendant(of: tabs2, matching: find.text('原著小说')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: tabs2, matching: find.text('原著小说')));
    await tester.pumpAndSettle();
    // 书区在列表底部，懒加载要先滚过去（区块未构建时锚点滚动无 context）。
    await _scrollTo(tester, find.text('立即阅读'));
    expect(find.text('三国：他们的武将技不太对劲'), findsOneWidget);
    expect(find.text('立即阅读'), findsOneWidget);
  });

  testWidgets('选集区头部右侧带完结状态（实机：已完结 共105集 ›）', (tester) async {
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
    );
    // 选集区在首屏之下（基本信息/剧评在前），懒加载列表要先滚过去。
    await _scrollTo(
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

  testWidgets('选集格子状态与点击：当前集主题色、已看灰字、点击回传下标', (tester) async {
    final played = <int>[];
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
      startIndex: 3,
      watchedIds: {'ep-0', 'ep-1', 'ep-2'},
      onPlay: (index) => played.add(index),
    );
    await _scrollTo(
      tester,
      find.byKey(const ValueKey('series-episode-6')),
      extra: 160,
    );
    // 当前集（第 4 格）亮 accent 底白字（真机实证 accent=HSL(色相,0.5,0.39)；
    // #F5E6C8 → #957432），右上角挂播放中 lottie 角标。
    final currentTile = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const ValueKey('series-episode-3')),
        matching: find.byType(Material),
      ),
    );
    expect(currentTile.color, const Color(0xFF957432));
    final current = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('series-episode-3')),
        matching: find.text('4'),
      ),
    );
    expect(current.style?.color, Colors.white);
    expect(current.style?.fontWeight, FontWeight.bold);
    // 已看集（第 1 格）灰字 #66FFFFFF（详情页深色皮肤，@color/agw 同族；
    // 播放页面板同款白系灰字）。
    final watched = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('series-episode-0')),
        matching: find.text('1'),
      ),
    );
    expect(watched.style?.color, const Color(0x66FFFFFF));
    // 点普通格回传该集下标。
    await tester.tap(find.byKey(const ValueKey('series-episode-6')));
    expect(played, [6]);
  });

  testWidgets('背景与主题色照官方 Zf/Df：series_color_hex 渐变 + 主色 accent', (
    tester,
  ) async {
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
    );
    // Scaffold 底色 = base；顶部 400dp 渐变 = top→base（Df 渐变层只占
    // 顶部 400dp，其余露纯主色；top = HSL(40°, 0.396, 0.334) ≈ #776033）。
    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('series-detail-page')),
    );
    expect(scaffold.backgroundColor, const Color(0xFF533D0F));
    // 底栏 scrim 也是渐变 DecoratedBox，这里只认背景那条两色渐变。
    final gradientBox = tester.widget<DecoratedBox>(
      find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient is LinearGradient &&
            ((w.decoration as BoxDecoration).gradient as LinearGradient)
                    .colors
                    .length ==
                2,
      ),
    );
    final gradient =
        (gradientBox.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors, const [Color(0xFF776033), Color(0xFF533D0F)]);
    // 底部「继续播放」钮 = 亮 accent 底白字（`g1.b` 的 n(l(), bright)；
    // #F5E6C8 的 accent = HSL(40°, 0.5, 0.39) ≈ #957432）。
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('series-detail-play-button')),
    );
    expect(button.style!.backgroundColor!.resolve({}), const Color(0xFF957432));
  });

  testWidgets('品牌色缺失/灰色系时回退官方 #404040（w4）', (tester) async {
    await _pump(
      tester,
      detail: _detail(seriesColorHex: ''),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
    );
    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('series-detail-page')),
    );
    expect(scaffold.backgroundColor, const Color(0xFF404040));
  });

  testWidgets('暗色品牌色不发散成浅背景（真机回归：#302010 深棕、白字可读）', (tester) async {
    // apiprobe 实抓 video_detail 样本 series_color_hex=#302010（HSL 30°,
    // 0.20, 0.125）。首版移植把 s0.b 上段起点误当分段点、上段终点误当 1.0，
    // 暗色输入 L 被映射到 0.949 → 近白背景配白字不可读。官方 s0.b 输出
    // 恒在暗色带（base L∈[0.18,0.2]）。
    await _pump(
      tester,
      detail: _detail(seriesColorHex: '#302010'),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
    );
    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('series-detail-page')),
    );
    expect(scaffold.backgroundColor, const Color(0xFF492E12));
    // 渐变顶部同样是暗色（muted 棕），不再是高亮色。
    // 底栏 scrim 也是渐变 DecoratedBox，这里只认背景那条两色渐变。
    final gradientBox = tester.widget<DecoratedBox>(
      find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient is LinearGradient &&
            ((w.decoration as BoxDecoration).gradient as LinearGradient)
                    .colors
                    .length ==
                2,
      ),
    );
    final gradient =
        (gradientBox.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors.first, const Color(0xFF694D30));
  });

  testWidgets('底部播放钮：续播文案照官方「继续播放」，点击回传当前下标', (tester) async {
    final played = <int>[];
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
      startIndex: 4,
      onPlay: (index) => played.add(index),
    );
    expect(
      find.byKey(const ValueKey('series-detail-bottombar')),
      findsOneWidget,
    );
    // 本地详情页明确展示续播集数。
    expect(find.text('继续播放 · 第5集'), findsOneWidget);
    expect(find.text('继续播放 第5集'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('series-detail-play-button')));
    expect(played, [4]);
  });

  testWidgets('无进度时底部按钮为「立即播放」', (tester) async {
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
    );
    expect(find.text('立即播放'), findsOneWidget);
  });

  testWidgets('底栏收藏写入本机书架并可取消', (tester) async {
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
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
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
      comments: _comments(),
    );
    expect(find.byKey(const ValueKey('series-detail-rate-card')), findsNothing);
    expect(find.text('看5分钟参与评分'), findsNothing);
    expect(find.byKey(const ValueKey('series-detail-more')), findsNothing);
  });

  testWidgets('长简介折叠 3 行：蓝色展开钮，点开展开全文并出现收起', (tester) async {
    const longIntro =
        '被公司开除的范理拒绝内耗，转身开起下午才营业的早餐店。凭真材实料和'
        '极致手艺，他把冷清侧门变成烟火聚场，也让邻里看见认真做事的人，终会被'
        '认可。可客流突然暴涨，神秘系统也在深夜亮起了面板，接下来他要面对的，'
        '是连锁品牌的挖角、供应商的刁难与一场突如其来的美食大赛。深夜的面板'
        '再次刷新，奖励从一笼小笼包升级到整套早餐车，也把麻烦一并送上了门：'
        '隔壁街的王记要搞买一送一，房东忽然要收回铺面，而系统任务倒计时只剩'
        '七天。范理决定不再一个人硬扛，他拉上早市上认识的老陈和夜班司机小'
        '林，把这份下午才营业的倔强，做成了整条街的早餐地图。';
    await _pump(
      tester,
      detail: _detail(intro: longIntro),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
    );
    // 折叠态：正文截断出「…」，右下角蓝色「展开」（官方 awv=#82A5CD）。
    final collapsed = tester.widget<Text>(
      find.byKey(const ValueKey('series-detail-intro')),
    );
    expect(collapsed.data, endsWith('…'));
    final expand = tester.widget<Text>(find.text('展开'));
    expect(expand.style?.color, const Color(0xFF82A5CD));
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
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
      comments: _comments(),
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

  testWidgets('超过 30 集出现分页条，切页显示对应区间', (tester) async {
    await _pump(
      tester,
      detail: _detail(episodeCount: 35),
      episodes: [for (var i = 0; i < 35; i++) _chapter(i)],
    );
    await _scrollTo(tester, find.text('1-30'));
    expect(find.byKey(const ValueKey('series-episode-pages')), findsOneWidget);
    expect(find.text('1-30'), findsOneWidget);
    expect(find.text('31-35'), findsOneWidget);
    // 第二页当前不可见：第 31 格不在树里。
    expect(find.byKey(const ValueKey('series-episode-30')), findsNothing);
    await tester.tap(find.text('31-35'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('series-episode-30')), findsOneWidget);
    expect(find.text('31'), findsOneWidget);
  });

  testWidgets('详情接口失败仍能以宿主兜底数据渲染（band 不阻塞）', (tester) async {
    await tester.pumpWidget(
      _host(
        SeriesDetailPage(
          seriesId: 'series-1',
          historyStore: MemoryReaderStore(),
          title: '兜底剧名',
          cover: '',
          episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
          seriesLoader: (_) async => SeriesDetail.empty,
          commentLoader: (_) async => const PlayletCommentPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 顶栏与头部各渲染一份兜底剧名。
    expect(find.text('兜底剧名'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('series-detail-title')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('series-detail-play-button')),
      findsOneWidget,
    );
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
                  episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
                  seriesLoader: (_) async => _detail(),
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

  testWidgets('异步目录按稳定 ID 恢复续播并定位第 31-60 集', (tester) async {
    final directory = Completer<List<List<Chapter>>>();
    final store = MemoryReaderStore(
      entry: {'episodeId': 'ep-45', 'episode': 2, 'position': 20.0},
    );
    store.watched['series-1'] = {'ep-45'};
    int? played;
    List<Chapter>? selectedEpisodes;
    await tester.pumpWidget(
      _host(
        SeriesDetailPage(
          seriesId: 'series-1',
          historyStore: store,
          initialDetail: _detail(episodeCount: 90),
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
    final episodes = [for (var i = 0; i < 90; i++) _chapter(i)];
    directory.complete([episodes]);
    await tester.pumpAndSettle();
    expect(find.text('继续播放 · 第46集'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('series-detail-play-button')));
    expect(played, 45);
    expect(selectedEpisodes, episodes);
    await _scrollTo(tester, find.byKey(const ValueKey('series-episode-45')));
    expect(find.byKey(const ValueKey('series-episode-0')), findsNothing);
  });

  testWidgets('第一集有历史也显示续播，宿主显式当前集优先于历史', (tester) async {
    final store = MemoryReaderStore(
      entry: {'episodeId': 'ep-0', 'position': 25},
    );
    for (final explicitIndex in <int?>[null, 2]) {
      await tester.pumpWidget(
        _host(
          SeriesDetailPage(
            key: UniqueKey(),
            seriesId: 'series-1',
            historyStore: store,
            initialDetail: _detail(),
            startIndex: explicitIndex,
            episodes: [for (var i = 0; i < 3; i++) _chapter(i)],
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
    await _pump(
      tester,
      detail: _detail(),
      episodes: [_chapter(0, disabled: true)],
      onPlay: (_) => played = true,
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('series-detail-play-button')),
    );
    expect(button.onPressed, isNull);
    await _scrollTo(tester, find.byKey(const ValueKey('series-episode-0')));
    final tile = tester.widget<Semantics>(
      find.byKey(const ValueKey('series-episode-0')),
    );
    expect(tile.properties.enabled, isFalse);
    expect(tile.properties.onTap, isNull);
    await tester.tap(find.byKey(const ValueKey('series-episode-0')));
    expect(played, isFalse);
  });

  testWidgets('目录失败可重试，空目录和失败文案区分', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      _host(
        SeriesDetailPage(
          seriesId: 'series-1',
          historyStore: MemoryReaderStore(),
          initialDetail: _detail(),
          directoryLoader: (_) async {
            if (++calls == 1) throw StateError('offline');
            return [
              [_chapter(0)],
            ];
          },
          commentLoader: (_) async => const PlayletCommentPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试加载'), findsOneWidget);
    expect(find.text('暂无剧集'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('series-detail-play-button')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('立即播放'), findsOneWidget);
  });

  testWidgets('详情与剧评分别重试，不重复加载成功的目录', (tester) async {
    var detailCalls = 0;
    var commentCalls = 0;
    var directoryCalls = 0;
    await tester.pumpWidget(
      _host(
        SeriesDetailPage(
          seriesId: 'series-1',
          title: '兜底标题',
          historyStore: MemoryReaderStore(),
          seriesLoader: (_) async =>
              ++detailCalls == 1 ? SeriesDetail.empty : _detail(),
          directoryLoader: (_) async {
            directoryCalls++;
            return [
              [_chapter(0)],
            ];
          },
          commentLoader: (_) async {
            if (++commentCalls == 1) throw StateError('offline');
            return _comments();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('详情加载失败'), findsOneWidget);
    await _scrollTo(tester, find.text('详情加载失败'));
    await tester.tap(find.text('重试').first);
    await tester.pumpAndSettle();
    expect(detailCalls, 2);
    expect(find.text('详情加载失败'), findsNothing);
    await _scrollTo(tester, find.text('剧评加载失败'));
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
      _host(
        SeriesDetailPage(
          seriesId: 'series-1',
          initialDetail: _detail(),
          episodes: [_chapter(0)],
          historyStore: MemoryReaderStore(),
          seriesLoader: (_) async {
            calls++;
            return _detail();
          },
          commentLoader: (_) => comments.future,
        ),
      ),
    );
    await tester.pump();
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    comments.complete(_comments());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字体与安全区：快捷选集可达，内容没有溢出', (tester) async {
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
          initialDetail: _detail(
            intro: '长简介包含表情👨‍👩‍👧‍👦，验证文字折叠和展开。' * 20,
            originalBook: const SeriesRelateBook(id: 'b1', title: '很长的原著小说书名'),
          ),
          episodes: [for (var i = 0; i < 90; i++) _chapter(i)],
          commentLoader: (_) async => _comments(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(const ValueKey('series-detail-episodes-shortcut')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('series-episode-0')).hitTestable(),
      findsOneWidget,
    );
    final firstTile = tester.getRect(
      find.byKey(const ValueKey('series-episode-0')),
    );
    final tabs = tester.getRect(
      find.byKey(const ValueKey('series-detail-tabs')),
    );
    expect(firstTile.top, greaterThanOrEqualTo(tabs.bottom));
    expect(tester.takeException(), isNull);
    await _scrollTo(tester, find.text('立即阅读'));
    expect(tester.takeException(), isNull);
  });
  testWidgets('长剧当前分组自动露出，横向定位不挪动详情锚点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(
      tester,
      detail: _detail(episodeCount: 300),
      episodes: [for (var i = 0; i < 300; i++) _chapter(i)],
      startIndex: 245,
    );
    await tester.tap(
      find.byKey(const ValueKey('series-detail-episodes-shortcut')),
    );
    await tester.pumpAndSettle();
    expect(find.text('241-270').hitTestable(), findsOneWidget);
    expect(
      find.byKey(const ValueKey('series-episode-240')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('背景实际像素铺满宽度，返回栏与吸顶导航没有异色横条', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: const EdgeInsets.only(top: 32)),
            child: child!,
          ),
          home: SeriesDetailPage(
            seriesId: 'series-1',
            historyStore: MemoryReaderStore(),
            initialDetail: _detail(seriesColorHex: '#302010'),
            episodes: [for (var i = 0; i < 90; i++) _chapter(i)],
            commentLoader: (_) async => _comments(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
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
      // 右边缘没有文字/封面：同时覆盖状态栏、返回栏上下边界、tab 和渐变尾部。
      for (final y in [20, 31, 32, 75, 76, 80, 100, 115, 200, 390, 410]) {
        final t = ((y + 0.5) / 400).clamp(0.0, 1.0);
        const top = [0x69, 0x4d, 0x30];
        const base = [0x49, 0x2e, 0x12];
        for (var channel = 0; channel < 3; channel++) {
          final actual = pixels!.getUint8((y * 360 + 358) * 4 + channel);
          final expected = top[channel] + (base[channel] - top[channel]) * t;
          expect(actual, closeTo(expected, 2), reason: 'y=$y channel=$channel');
        }
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
