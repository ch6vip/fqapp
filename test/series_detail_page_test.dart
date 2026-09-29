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
  episodeLabel: '已完结 共12集',
  playCount: 87000,
  followerCount: 1200,
  commentCount: 0,
  categories: const ['历史', '搞笑'],
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
    _host(
      SeriesDetailPage(
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
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('头部按官方 a34 规格：标题 2 行内、状态角标、分类 chips、分隔线', (
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
    // 封面右上角状态胶囊（官方 jgn）。
    expect(find.byKey(const ValueKey('series-detail-cover-badge')), findsOneWidget);
    expect(find.text('已完结'), findsOneWidget);
    // 状态行：官方 episodeLabel「已完结 共12集」+ 播放量 + 追更数。
    expect(find.text('已完结 共12集 · 8.7万次播放 · 1200人追更'), findsOneWidget);
    // 分类 chips（官方 RecommendTagLayout）。
    expect(find.byKey(const ValueKey('series-detail-categories')), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('搞笑'), findsOneWidget);
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

  testWidgets('底部播放钮：续播态文案带集号，点击回传当前下标', (tester) async {
    final played = <int>[];
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
      startIndex: 4,
      onPlay: (index) => played.add(index),
    );
    expect(find.byKey(const ValueKey('series-detail-bottombar')), findsOneWidget);
    expect(find.text('继续播放 第5集'), findsOneWidget);
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

  testWidgets('tab 切换：基本信息显示简介与演职人员，剧评显示预览与查看全部', (
    tester,
  ) async {
    await _pump(
      tester,
      detail: _detail(),
      episodes: [for (var i = 0; i < 12; i++) _chapter(i)],
      comments: _comments(),
    );
    // tab 行固定在顶栏下（官方 AppBarLayout 行为）；点「剧评」滚动锚点，
    // 剧评预览进入视口。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('series-detail-tabs')),
        matching: find.text('剧评'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('这剧可以看'), findsOneWidget);
    expect(find.text('查看全部剧评'), findsOneWidget);
    // tab 行点亮逻辑：点「剧评」滚动锚点（限定 tab 行，避免命中区块标题）。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('series-detail-tabs')),
        matching: find.text('剧评'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('期待你的第一条剧评'), findsNothing);
  });

  testWidgets('超过 30 集出现分页条，切页显示对应区间', (tester) async {
    await _pump(
      tester,
      detail: _detail(episodeCount: 35),
      episodes: [for (var i = 0; i < 35; i++) _chapter(i)],
    );
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
