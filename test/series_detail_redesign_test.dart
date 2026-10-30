import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/app_theme.dart' show einkModeNotifier;
import 'package:fqapp/widgets/home/home_design.dart' show HomePalette;

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

/// 短剧详情改版的回归：跟随应用主题、选集上移、50 集分段 / 倒序、
/// 区块标题右对齐、空详情容错与桌面剧评卡限宽。
///
/// 既有行为仍在 `series_detail_page_test.dart`。
void main() {
  testWidgets('跟随浅色主题：画布 + 剧集主色淡色带 + 品牌强调色播放钮', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
    );
    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('series-detail-page')),
    );
    expect(scaffold.backgroundColor, const Color(0xFFF6F6F6));
    // 色带顶部 = 剧集主色 #F5E6C8 按 10% 混到画布，然后淡出到画布。
    final bandTop = Color.alphaBlend(
      const Color(0xFFF5E6C8).withValues(alpha: 0.10),
      const Color(0xFFF6F6F6),
    );
    final gradientBox = tester.widget<DecoratedBox>(twoColorGradientFinder());
    final gradient =
        (gradientBox.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors, [bandTop, const Color(0xFFF6F6F6)]);
    // 播放钮 = 品牌强调色。
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('series-detail-play-button')),
    );
    expect(button.style!.backgroundColor!.resolve({}), HomePalette.accent);
  });

  testWidgets('灰色系 / 缺失品牌色时不出色带（页面就是画布色）', (tester) async {
    for (final hex in <String>['', '#404040']) {
      await pumpSeriesDetail(
        tester,
        detail: seriesDetailFixture(seriesColorHex: hex),
        episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
      );
      final scaffold = tester.widget<Scaffold>(
        find.byKey(const ValueKey('series-detail-page')),
      );
      expect(scaffold.backgroundColor, const Color(0xFFF6F6F6));
      expect(twoColorGradientFinder(), findsNothing);
    }
  });

  testWidgets('跟随深色主题：深色画布，主色只做更实的暗色带（不再强制深色背景）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: KeyedSubtree(
          key: UniqueKey(),
          child: SeriesDetailPage(
            seriesId: 'series-1',
            historyStore: MemoryReaderStore(),
            title: '抽象三国第一季',
            cover: '',
            episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
            seriesLoader: (_) async =>
                seriesDetailFixture(seriesColorHex: '#302010'),
            commentLoader: (_) async => const PlayletCommentPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('series-detail-page')),
    );
    expect(scaffold.backgroundColor, const Color(0xFF151517));
    final bandTop = Color.alphaBlend(
      const Color(0xFF302010).withValues(alpha: 0.16),
      const Color(0xFF151517),
    );
    // 仍是暗色，白字可读。
    expect(bandTop.computeLuminance(), lessThan(0.1));
    final gradientBox = tester.widget<DecoratedBox>(twoColorGradientFinder());
    final gradient =
        (gradientBox.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors, [bandTop, const Color(0xFF151517)]);
  });

  testWidgets('墨水屏：纯黑白、没有色带，播放钮与当前集用纯黑', (tester) async {
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = false);
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
      startIndex: 2,
    );
    final scaffold = tester.widget<Scaffold>(
      find.byKey(const ValueKey('series-detail-page')),
    );
    expect(scaffold.backgroundColor, Colors.white);
    expect(twoColorGradientFinder(), findsNothing);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('series-detail-play-button')),
    );
    expect(button.style!.backgroundColor!.resolve({}), Colors.black);
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episode-2')),
    );
    final currentTile = tester.widget<Material>(
      find.descendant(
        of: find.byKey(const ValueKey('series-episode-2')),
        matching: find.byType(Material),
      ),
    );
    expect(currentTile.color, Colors.black);
    final label = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('series-episode-2')),
        matching: find.text('3'),
      ),
    );
    expect(label.style?.color, Colors.white);
  });

  testWidgets('桌面宽屏：剧评卡限制最大宽度，不再拉满整屏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
      comments: commentsFixture(),
    );
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-detail-comment-card-0')),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('series-detail-comment-card-0')))
          .width,
      420,
    );
  });

  testWidgets('详情返回空不是失败：照常渲染目录与播放钮', (tester) async {
    await tester.pumpWidget(
      hostPage(
        SeriesDetailPage(
          seriesId: 'series-1',
          historyStore: MemoryReaderStore(),
          title: '兜底剧名',
          cover: '',
          episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
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
    // 空详情不报失败，也不影响选集。
    expect(find.text('详情加载失败'), findsNothing);
    expect(find.text('重试加载'), findsNothing);
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episode-grid')),
    );
    expect(find.byKey(const ValueKey('series-episode-0')), findsOneWidget);
  });

  testWidgets('区块顺序：播放钮 → 选集 → 简介', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
    );
    final play = tester.getRect(
      find.byKey(const ValueKey('series-detail-play-button')),
    );
    final grid = tester.getRect(
      find.byKey(const ValueKey('series-episode-grid')),
    );
    final intro = tester.getRect(
      find.byKey(const ValueKey('series-detail-intro-section')),
    );
    expect(play.bottom, lessThan(grid.top));
    expect(grid.top, lessThan(intro.top));
  });

  testWidgets('选集头部右侧的状态与「同系列」右对齐且同在一行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(relatedAlbumId: '99'),
      episodes: [for (var i = 0; i < 12; i++) chapterAt(i)],
    );
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episode-status')),
    );
    final title = tester.getRect(find.text('选集'));
    final status = tester.getRect(
      find.byKey(const ValueKey('series-episode-status')),
    );
    final related = tester.getRect(
      find.byKey(const ValueKey('series-detail-related-series')),
    );
    // 两段动作都在标题右侧，同一条基线，右端贴 16dp 栏距。
    expect(status.left, greaterThan(title.right));
    expect(status.center.dy, closeTo(related.center.dy, 2));
    expect(related.right, closeTo(360 - 16, 1));
  });

  testWidgets('选集分段 50 集一段，倒序把本段最后一集排到最前', (tester) async {
    await pumpSeriesDetail(
      tester,
      detail: seriesDetailFixture(episodeCount: 80),
      episodes: [for (var i = 0; i < 80; i++) chapterAt(i)],
    );
    await scrollToWidget(tester, find.text('1–50'));
    expect(find.text('1–50'), findsOneWidget);
    expect(find.text('51–80'), findsOneWidget);
    // 正序：第 1 集在第一行。
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('series-episode-0'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('series-episode-49'))).dy,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('series-episode-reverse')));
    await tester.pumpAndSettle();
    // 倒序：第 50 集排到最前。
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('series-episode-49'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('series-episode-0'))).dy,
      ),
    );
  });
}
