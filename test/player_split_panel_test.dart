import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/player_split_panel.dart';

void main() {
  Future<List<int>> mount(
    WidgetTester tester, {
    Size window = const Size(407, 500),
    int currentIndex = 2,
    int commentCount = 12,
    int loadedTotal = 12,
    TextScaler textScaler = TextScaler.noScaling,
    int episodeCount = 40,
  }) async {
    // setSurfaceSize 只改布局尺寸，MediaQuery.size 仍是默认 800x600，
    // 面板会按横置排版；直接改视图尺寸让两者一致。
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final selected = <int>[];
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: Scaffold(
          body: PlayerSplitPanel(
            seriesId: 'series-1',
            title: '测试短剧',
            cover: '',
            episodeLabel: '更新至第3集',
            status: '连载中',
            synopsis: '一句简介',
            episodes: List.generate(
              episodeCount,
              (index) => Chapter(
                itemId: '${index + 1}',
                title: '第${index + 1}集',
                volumeName: '',
              ),
            ),
            currentIndex: currentIndex,
            playingIndex: null,
            playing: false,
            watched: const {0, 1},
            commentCount: commentCount,
            onSelectEpisode: selected.add,
            onOpenSeriesDetail: () => actions.add('series'),
            onOpenRelatedSeries: () => actions.add('related'),
            onOpenListenMode: () => actions.add('listen'),
            onOpenDownload: () => actions.add('download'),
            commentLoader:
                ({
                  required int sort,
                  required int count,
                  required String cursor,
                  required String tag,
                }) async => PlayletCommentPage(totalCount: loadedTotal),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    // 返回可变引用，调用方只读。
    return selected;
  }

  /// 挂一个「窗口尺寸」「面板盒子尺寸」「宿主注入的轴向」三者可独立设定的
  /// 用例：面板只是窗口里裁出的一条窄边，轴向必须由宿主给。
  Future<void> mountInBox(
    WidgetTester tester, {
    required Size window,
    required Size box,
    bool? axis,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget panel = PlayerSplitPanel(
      seriesId: 'series-1',
      title: '测试短剧',
      cover: '',
      episodeLabel: '更新至第3集',
      status: '连载中',
      synopsis: '一句简介',
      episodes: List.generate(
        3,
        (index) => Chapter(
          itemId: '${index + 1}',
          title: '第${index + 1}集',
          volumeName: '',
        ),
      ),
      currentIndex: 0,
      playingIndex: null,
      playing: false,
      watched: const {},
      commentCount: 0,
      onSelectEpisode: (_) {},
    );
    if (axis != null) panel = SplitPanelAxis(sideBySide: axis, child: panel);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: box.width, height: box.height, child: panel),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  RoundedRectangleBorder panelShape(WidgetTester tester) =>
      tester
              .widget<Material>(
                find.byKey(const ValueKey('player-split-panel')),
              )
              .shape
          as RoundedRectangleBorder;

  testWidgets('横屏右侧栏是「比高还窄」的竖条，仍按左右分屏排版', (tester) async {
    // 真机横屏分屏：窗口 900×420，右侧栏约 324×420（宽 < 高）。旧实现按
    // 面板自身宽高比判，会把它当成底部竖抽屉（圆角方向、列数都反）。
    await mountInBox(
      tester,
      window: const Size(900, 420),
      box: const Size(324, 420),
      axis: true,
    );
    expect(
      panelShape(tester).borderRadius,
      const BorderRadius.horizontal(left: Radius.circular(14)),
    );
  });

  testWidgets('宿主注入的轴向优先于窗口比例', (tester) async {
    // 窗口横置，但宿主说是上下分屏（竖屏分屏后设备rotation没变情形）。
    await mountInBox(
      tester,
      window: const Size(800, 600),
      box: const Size(400, 300),
      axis: false,
    );
    expect(
      panelShape(tester).borderRadius,
      const BorderRadius.vertical(top: Radius.circular(14)),
    );
  });

  testWidgets('宿主未注入时退回窗口比例', (tester) async {
    await mountInBox(
      tester,
      window: const Size(400, 900),
      box: const Size(700, 360),
    );
    expect(
      panelShape(tester).borderRadius,
      const BorderRadius.vertical(top: Radius.circular(14)),
    );
  });

  testWidgets('the synopsis tab keeps the series info and episode entry', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byKey(const ValueKey('player-split-panel')), findsOneWidget);
    // B 站式分页：顶部只剩「简介 / 评论」，集数入口收进简介页。
    expect(find.text('简介'), findsOneWidget);
    expect(find.text('选集'), findsOneWidget);
    expect(find.text('测试短剧'), findsOneWidget);
    expect(find.text('更新至第3集 · 连载中 · 全40集'), findsOneWidget);
    expect(find.text('一句简介'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-split-episode-count')),
      findsOneWidget,
    );
    expect(find.text('第3/40集'), findsOneWidget);
    for (final label in ['作品详情', '同系列', '听剧', '下载']) {
      expect(
        find.byKey(ValueKey('player-split-action-$label')),
        findsOneWidget,
      );
    }
  });

  testWidgets('episode grid is six columns and reports the tapped index', (
    tester,
  ) async {
    final selected = await mount(tester);
    final first = tester.getRect(find.byKey(const ValueKey('story-episode-0')));
    expect(
      tester.getRect(find.byKey(const ValueKey('story-episode-5'))).top,
      closeTo(first.top, .1),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('story-episode-6'))).top,
      greaterThan(first.bottom),
    );
    expect(first.width, closeTo((407 - 24 - 40) / 6, 1));

    await tester.tap(find.byKey(const ValueKey('story-episode-5')));
    await tester.pump();
    expect(selected, [5]);
  });

  testWidgets('comments stay unbuilt until the tab is opened', (tester) async {
    await mount(tester);
    expect(
      find.byKey(const ValueKey('player-split-comments-series-1')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('player-split-tab-1')));
    // PageView 的翻页动画（220ms）结束后评论页才完整落位，加载态也在
    // 这期间完成。
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('player-split-comments-series-1')),
      findsOneWidget,
    );
    // 嵌入态隐藏「剧评」头部，但保留筛选行与空态。
    expect(find.text('剧评'), findsNothing);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);
    expect(find.text('无相关剧评'), findsOneWidget);
    expect(find.text('评论 12'), findsOneWidget);

    // 评论页独占 Tab 行以下的全部高度：剧信息头部只在简介页，
    // 不再从评论列表里切走一块。
    final panelHeight = tester
        .getRect(find.byKey(const ValueKey('player-split-panel')))
        .height;
    final comments = tester.getRect(
      find.byKey(const ValueKey('player-split-comments-series-1')),
    );
    expect(comments.top, closeTo(43, 1));
    expect(comments.height, closeTo(panelHeight - 43, 1));
    expect(find.text('测试短剧'), findsNothing);

    // 切回选集后两个 Tab 都还在（PageView + keep-alive 保留状态）。非当前
    // 子页对 finder 属于 offstage，要显式关掉 skipOffstage 才看得到。
    await tester.tap(find.byKey(const ValueKey('player-split-tab-0')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey('player-split-comments-series-1'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('story-episode-0')), findsOneWidget);
  });

  testWidgets('a landscape surface lays the episode grid out in four columns', (
    tester,
  ) async {
    await mount(tester, window: const Size(900, 420));
    final first = tester.getRect(find.byKey(const ValueKey('story-episode-0')));
    expect(
      tester.getRect(find.byKey(const ValueKey('story-episode-3'))).top,
      closeTo(first.top, .1),
    );
    expect(first.width, closeTo((900 - 24 - 24) / 4, 1));

    // 900 宽的面板把格子撑到约 209 高，一屏放不下第二行：先向上滚一段，
    // 再确认第 5 个格子另起一行（滚动后第一行仍在视口内）。
    await tester.drag(
      find.byKey(const ValueKey('story-episodes')),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
    final fourth = tester.getRect(
      find.byKey(const ValueKey('story-episode-3')),
    );
    final fifth = tester.getRect(find.byKey(const ValueKey('story-episode-4')));
    expect(fifth.top, greaterThan(fourth.bottom));
  });

  testWidgets('horizontal swipe switches between episodes and comments', (
    tester,
  ) async {
    await mount(tester);

    await tester.fling(
      find.byKey(const ValueKey('player-split-pager')),
      const Offset(-320, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-split-comments-series-1')),
      findsOneWidget,
    );
    expect(find.text('无相关剧评'), findsOneWidget);

    await tester.fling(
      find.byKey(const ValueKey('player-split-pager')),
      const Offset(320, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('story-episode-0')), findsOneWidget);
    // 切回选集后评论页仍然保活（横滑不丢状态）。
    expect(
      find.byKey(
        const ValueKey('player-split-comments-series-1'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets('the tab count follows the total reported by the list', (
    tester,
  ) async {
    await mount(tester, loadedTotal: 15);
    expect(find.text('评论 12'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-split-tab-1')));
    await tester.pumpAndSettle();

    // 列表拉到服务端总数后，Tab 上的计数必须跟着更新，不能停在进页快照。
    expect(find.text('评论 15'), findsOneWidget);
    expect(find.text('评论 12'), findsNothing);
  });

  testWidgets('oversized text clamps header lines and keeps the list', (
    tester,
  ) async {
    await mount(tester, textScaler: const TextScaler.linear(2));

    expect(tester.takeException(), isNull);
    expect(tester.widget<Text>(find.text('测试短剧')).maxLines, 1);
    expect(tester.widget<Text>(find.text('一句简介')).maxLines, 1);
    expect(find.byKey(const ValueKey('story-episode-0')), findsOneWidget);
  });

  testWidgets('an empty episode list keeps the entry without a fake count', (
    tester,
  ) async {
    await mount(tester, episodeCount: 0);

    expect(
      find.byKey(const ValueKey('player-split-episode-count')),
      findsOneWidget,
    );
    // 加载中/失败时不能显示「第1/0集」，空态由网格自己说明。
    expect(find.text('第1/0集'), findsNothing);
    expect(find.text('暂无剧集'), findsWidgets);
  });

  testWidgets('a squeezed panel keeps the synopsis tab from overflowing', (
    tester,
  ) async {
    // 竖屏分屏比例最低可拖到 25%：这里的面板只剩 160 高，简介页扣掉
    // Tab 行只有 117，剧信息头部 + 选集行的自然高度会撑破这一页。
    await mount(tester, window: const Size(300, 160));

    expect(tester.takeException(), isNull);
    // 头部连封面都放不下时收起，选集入口与网格必须还在。
    expect(find.text('测试短剧'), findsNothing);
    expect(
      find.byKey(const ValueKey('player-split-episode-count')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('story-episode-0')), findsOneWidget);
  });

  testWidgets('a narrow panel scales the tab row down instead of overflowing', (
    tester,
  ) async {
    // 左右分栏拖到最窄时真机面板只剩 121dp，Tab 行的自然宽度约 132dp，
    // 直接放 Row 会撑爆（2026-10-25 app.log 两条 RenderFlex overflowed
    // by 17 pixels）。条带要等比缩小，评论计数也不许被丢掉。
    await mount(tester, window: const Size(124, 300));

    expect(tester.takeException(), isNull);
    expect(find.text('简介'), findsOneWidget);
    expect(find.text('评论 12'), findsOneWidget);
    // 缩的是内容而不是条带：Tab 仍在 42 高的行里，两个标签都放得下。
    final first = tester.getRect(
      find.byKey(const ValueKey('player-split-tab-0')),
    );
    final second = tester.getRect(
      find.byKey(const ValueKey('player-split-tab-1')),
    );
    expect(first.height, lessThanOrEqualTo(42));
    expect(second.right, lessThanOrEqualTo(124));
    expect(second.left, greaterThan(first.left));

    // 评论页也得能在这么窄的面板里站住（列表行有头像/点赞数等固定宽度）。
    await tester.tap(find.byKey(const ValueKey('player-split-tab-1')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
