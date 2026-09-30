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
}) => SeriesDetail(
  seriesId: 'series-1',
  title: '抽象三国第一季',
  intro: '这是一段剧集简介，用于基本信息区块的展开收起验证。',
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
          title: detail.title,
          cover: detail.cover,
          episodes: episodes,
          startIndex: startIndex,
          watchedIds: watchedIds,
          seriesLoader: (_) async => detail,
          commentLoader: comments == null
              ? (_) async => const PlayletCommentPage()
              : (_) async => comments,
          onPlayEpisode: onPlay ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 把内容滚到目标组件可见（选集/原著等区块在首屏之下）。
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.dragUntilVisible(
    finder,
    find.byKey(const ValueKey('series-detail-content')),
    const Offset(0, -160),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('头部按官方 a34 规格：标题 2 行内、状态行、分类 chips、无封面角标', (
    tester,
  ) async {
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
    // 状态行：官方 episodeLabel「全12集」+ 播放量 + 追更数。
    expect(find.text('全12集 · 8.7万次播放 · 1200人追更'), findsOneWidget);
    // 分类 chips（官方 RecommendTagLayout）。
    expect(find.byKey(const ValueKey('series-detail-categories')), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('搞笑'), findsOneWidget);
  });

  testWidgets('tab 结构照实机：基本信息/剧评，无选集；有原著时出现原著小说', (
    tester,
  ) async {
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
    expect(find.descendant(of: tabs, matching: find.text('剧评')), findsOneWidget);
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
    await tester.tap(
      find.descendant(of: tabs2, matching: find.text('原著小说')),
    );
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
    await _scrollTo(tester, find.text('选集'));
    final status = tester.widget<Text>(
      find.byKey(const ValueKey('series-episode-status')),
    );
    expect(status.data, '已完结 共12集');
    // 选集区块标题存在（无 tab，但区块在）。
    expect(find.text('选集'), findsOneWidget);
  });

  testWidgets('选集格子状态与点击：当前集橙字、已看灰字、点击回传下标', (tester) async {
    final played = <int>[];
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
      startIndex: 3,
      watchedIds: {'ep-0', 'ep-1', 'ep-2'},
      onPlay: (index) => played.add(index),
    );
    await _scrollTo(tester, find.byKey(const ValueKey('series-episode-6')));
    // 当前集（第 4 格）橙字 #FFFA6725（官方 @color/aok）。
    final current = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('series-episode-3')),
        matching: find.text('4'),
      ),
    );
    expect(current.style?.color, const Color(0xFFFA6725));
    expect(current.style?.fontWeight, FontWeight.bold);
    // 已看集（第 1 格）灰字 #66000000（官方 skin_color_gray_40_light）。
    final watched = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('series-episode-0')),
        matching: find.text('1'),
      ),
    );
    expect(watched.style?.color, const Color(0x66000000));
    // 点普通格回传该集下标。
    await tester.tap(find.byKey(const ValueKey('series-episode-6')));
    expect(played, [6]);
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
    expect(find.byKey(const ValueKey('series-detail-bottombar')), findsOneWidget);
    // 实机官方文案是「继续播放」，不带集号。
    expect(find.text('继续播放'), findsOneWidget);
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
    expect(find.text('剧评'), findsNWidgets(2));
    expect(find.text(' · 952'), findsOneWidget);
    expect(find.byKey(const ValueKey('series-detail-comments-all')), findsOneWidget);
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
          title: '兜底剧名',
          cover: '',
          episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
          seriesLoader: (_) async => SeriesDetail.empty,
          commentLoader: (_) async => const PlayletCommentPage(),
          onPlayEpisode: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 顶栏与头部各渲染一份兜底剧名。
    expect(find.text('兜底剧名'), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('series-detail-title')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('series-detail-play-button')), findsOneWidget);
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
                  title: '抽象三国第一季',
                  cover: '',
                  episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
                  seriesLoader: (_) async => _detail(),
                  commentLoader: (_) async => const PlayletCommentPage(),
                  onPlayEpisode: (_) {},
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
}
