import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/player/story_player_panel.dart';

/// F06 第二批：选集面板**头部剧信息**。
///
/// 官方依据：
/// - 头部区块 `aa8.xml:7-15`（封面 `hdb`、标题 `hdt`、右箭头 `right_icon`、
///   集数行 `he1`、免费角标 `dga`）；收藏 `ddg` 按用户要求移除。
/// - 集数/状态文案 `a1.java:554-568`（`A2()`）与 `:2034-2056`（`o1()`）：
///   电影 -> 「电影 · 共N分钟」；虚幻短剧 -> `d6d`「暂未上线」；
///   更新中 -> `e6s`「更新至%s集」（漫改 `e6u`「看到%s集/更新至%s集」）；
///   其余 -> `e6q`「已完结 共%s集」
/// - 免费角标：文 `@string/c3q`「免费观看」、字色 #FF00AE83、底 #1A00AE83
void main() {
  List<Chapter> episodes(int count) => [
    for (var i = 0; i < count; i++)
      Chapter(itemId: 'v$i', title: '第 ${i + 1} 集', volumeName: '剧集'),
  ];

  Future<void> pump(
    WidgetTester tester, {
    String title = '我的短剧',
    String cover = '',
    String label = '更新至12集',
    bool freeWatch = false,
    VoidCallback? onOpenSeries,
  }) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: StoryPlayerPanel(
              scrollController: scroll,
              episodes: episodes(6),
              currentIndex: 0,
              playingIndex: 0,
              playing: true,
              seriesTitle: title,
              seriesCover: cover,
              episodeLabel: label,
              freeWatch: freeWatch,
              onOpenSeries: onOpenSeries,
              onSelectEpisode: (_) {},
              onDragStart: (_) {},
              onDragUpdate: (_) {},
              onDragEnd: (_) {},
              onDragCancel: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('集数文案', () {
    test('an updating series says how far it has updated', () {
      expect(
        seriesEpisodeLabel(
          status: SeriesStatus.updating,
          count: 12,
          currentIndex: 3,
        ),
        '更新至12集',
      );
    });

    test('a finished series says how many episodes there are', () {
      expect(
        seriesEpisodeLabel(
          status: SeriesStatus.finished,
          count: 66,
          currentIndex: 3,
        ),
        '已完结 共66集',
      );
      // 今日更新/断更都走官方同一条兜底分支。
      expect(
        seriesEpisodeLabel(
          status: SeriesStatus.updateToday,
          count: 66,
          currentIndex: 0,
        ),
        '已完结 共66集',
      );
      expect(
        seriesEpisodeLabel(
          status: SeriesStatus.updateStop,
          count: 5,
          currentIndex: 0,
        ),
        '已完结 共5集',
      );
    });

    test('a motion comic adds the current episode', () {
      expect(
        seriesEpisodeLabel(
          status: SeriesStatus.updating,
          count: 30,
          currentIndex: 4,
          motionComic: true,
        ),
        '看到5集/更新至30集',
      );
    });

    test('an unreal short play is not online yet', () {
      expect(
        seriesEpisodeLabel(
          status: SeriesStatus.finished,
          count: 10,
          currentIndex: 0,
          unrealShortPlay: true,
        ),
        '暂未上线',
      );
    });

    test('a movie label rounds the duration up to minutes', () {
      expect(
        seriesEpisodeLabel(
          status: SeriesStatus.finished,
          count: 0,
          currentIndex: 0,
          durationSeconds: 5400,
        ),
        '电影 · 共90分钟',
      );
      // 不足一分钟也要显示 1 分钟，不能显示「共0分钟」。
      expect(
        seriesEpisodeLabel(
          status: SeriesStatus.finished,
          count: 0,
          currentIndex: 0,
          durationSeconds: 20,
        ),
        '电影 · 共1分钟',
      );
    });

    test('an unknown series with episodes still shows the count', () {
      expect(
        seriesEpisodeLabel(status: null, count: 8, currentIndex: 0),
        '已完结 共8集',
      );
      expect(seriesEpisodeLabel(status: null, count: 0, currentIndex: 0), '');
    });
  });

  group('头部区块', () {
    testWidgets('the header carries the title, label and free badge', (
      tester,
    ) async {
      await pump(tester, label: '更新至12集', freeWatch: true);
      expect(
        find.byKey(const ValueKey('story-panel-series-header')),
        findsOneWidget,
      );
      expect(find.text('我的短剧'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('story-panel-episode-label')),
        findsOneWidget,
      );
      expect(find.text('更新至12集'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('story-panel-free-badge')),
        findsOneWidget,
      );
      expect(find.text('免费观看'), findsOneWidget);
    });

    testWidgets('the header disappears when there is nothing to show', (
      tester,
    ) async {
      await pump(tester, title: '', label: '');
      expect(
        find.byKey(const ValueKey('story-panel-series-header')),
        findsNothing,
      );
      // 没有头部时集数格子仍然在。
      expect(find.byKey(const ValueKey('story-episode-0')), findsOneWidget);
    });

    testWidgets('the free badge is absent unless the series is free', (
      tester,
    ) async {
      await pump(tester);
      expect(
        find.byKey(const ValueKey('story-panel-free-badge')),
        findsNothing,
      );
    });

    testWidgets('the title still opens the series without a collect button', (
      tester,
    ) async {
      var opens = 0;
      await pump(tester, onOpenSeries: () => opens++);
      await tester.tap(find.byKey(const ValueKey('story-panel-series-title')));
      await tester.pump();
      expect(opens, 1);
      expect(find.byKey(const ValueKey('story-panel-collect')), findsNothing);
      expect(find.text('收藏'), findsNothing);
      expect(find.text('已收藏'), findsNothing);
    });

    testWidgets('without callbacks the header has no arrow and no collect', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      expect(find.byKey(const ValueKey('story-panel-collect')), findsNothing);
    });
  });
}
