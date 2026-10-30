import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/widgets/player/story_player_panel.dart' show SeriesStatus;

import 'fakes.dart';

/// 短剧详情两个测试文件共用的样例数据与挂载 / 滚动工具。
///
/// `series_detail_page_test.dart` 放既有行为，`series_detail_redesign_test.dart`
/// 放改版新增的版式与主题回归；两边都用这一份，避免样例漂移。

Chapter chapterAt(int index, {bool disabled = false}) => Chapter(
  itemId: 'ep-$index',
  title: '第${index + 1}集',
  volumeName: '',
  disabled: disabled,
);

SeriesDetail seriesDetailFixture({
  int? status = SeriesStatus.finished,
  int episodeCount = 12,
  String episodeLabel = '全12集',
  SeriesRelateBook? originalBook,
  String seriesColorHex = '#F5E6C8',
  String intro = '这是一段剧集简介，用于基本信息区块的展开收起验证。',
  String relatedAlbumId = '',
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
  relatedAlbumId: relatedAlbumId,
);

PlayletCommentPage commentsFixture() => const PlayletCommentPage(
  comments: [
    PlayletComment(id: 'm1', text: '这剧可以看', userName: '观众甲', diggCount: 22000),
    PlayletComment(id: 'm2', text: '武将技不太对劲', userName: '观众乙', diggCount: 5575),
  ],
  totalCount: 952,
);

Widget hostPage(Widget child) => MaterialApp(home: child);

/// 两色渐变的 [DecoratedBox]：页面背景色带。
Finder twoColorGradientFinder() => find.byWidgetPredicate(
  (w) =>
      w is DecoratedBox &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).gradient is LinearGradient &&
      ((w.decoration as BoxDecoration).gradient as LinearGradient)
              .colors
              .length ==
          2,
);

Future<void> pumpSeriesDetail(
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
    hostPage(
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
          // null 时走页面默认「推新播放器」；宿主接线（onPlay 传入）才
          // 视为播放中——与真机语义一致。
          onPlayEpisode: onPlay,
        ),
      ),
    ),
  );
  // 用固定步进 pump 等布局与惯性滚动落地。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// 把内容滚到目标组件可见（选集/原著等区块可能在首屏之下）；[extra] 再额外
/// 上移（贴底的目标用）。
Future<void> scrollToWidget(
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
  // 拖拽末端的惯性滚动需要落地，步进 pump 而不是 pumpAndSettle。
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
