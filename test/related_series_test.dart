import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/related_series.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/widgets/player/related_series_sheet.dart';

void main() {
  test(
    'official plan cell preserves series IDs and excludes unrelated videos',
    () {
      final fixture =
          jsonDecode(
                File('rust/testdata/series_related.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final entries = RelatedSeries.fromPayload(
        fixture['response'] as Map<String, dynamic>,
        currentSeriesId: fixture['series_id'] as String,
      );
      expect(entries.map((entry) => entry.id), [
        '7612345678901234568',
        '7612345678901234569',
        '7612345678901234570',
      ]);
      expect(entries.first.episodeCount, 36);
      expect(entries[1].unavailable, isTrue);
      expect(entries[2].kind, 'manju');
    },
  );

  test(
    'same-series availability is driven by the album relation, not recommendations',
    () {
      SeriesDetail detail(dynamic relation) => SeriesDetail.fromPayload({
        'code': 0,
        'data': {
          'video_data': {'related_album_id': relation},
        },
      });
      expect(detail('7612345678901234567').hasRelatedSeries, isTrue);
      for (final relation in [null, '', 'bad', 0, -1]) {
        expect(detail(relation).hasRelatedSeries, isFalse);
      }
    },
  );

  testWidgets(
    'unavailable seasons cannot be selected and retry keeps exact target',
    (tester) async {
      var attempts = 0;
      RelatedSeries? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await showModalBottomSheet<RelatedSeries>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => RelatedSeriesSheet(
                    seriesId: '1',
                    loader: (_) async {
                      if (++attempts == 1) {
                        throw const FormatException('bad response');
                      }
                      return const [
                        RelatedSeries(id: '2', title: '下一季'),
                        RelatedSeries(id: '3', title: '待上线', unavailable: true),
                      ];
                    },
                  ),
                );
              },
              child: const Text('选系列'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选系列'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('待上线'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(find.text('下一季'));
      await tester.pumpAndSettle();
      expect(selected?.id, '2');
    },
  );

  testWidgets('closing while loading ignores a late response', (tester) async {
    final pending = Completer<List<RelatedSeries>>();
    await tester.pumpWidget(
      MaterialApp(
        home: RelatedSeriesSheet(seriesId: '1', loader: (_) => pending.future),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(const [RelatedSeries(id: '2', title: '下一季')]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('related seasons render as a two-column grid', (tester) async {
    // 官方 `catalogdialog/view/s` 的双列形态（`enableDoubleRow`）：前三项应有
    // 两个落在同一行，且卡片带「共 N 集」。
    await tester.pumpWidget(
      MaterialApp(
        home: RelatedSeriesSheet(
          seriesId: '1',
          loader: (_) async => const [
            RelatedSeries(id: '2', title: '第二季', episodeCount: 96),
            RelatedSeries(id: '3', title: '第三季', episodeCount: 96),
            RelatedSeries(id: '4', title: '第四季', episodeCount: 96),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = tester.getTopLeft(
      find.byKey(const ValueKey('related-series-2')),
    );
    final second = tester.getTopLeft(
      find.byKey(const ValueKey('related-series-3')),
    );
    expect(second.dy, closeTo(first.dy, 0.5), reason: '前两张卡应在同一行');
    expect(second.dx, greaterThan(first.dx), reason: '第二张卡应在其右侧');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the player side panel matches the episode drawer geometry', (
    tester,
  ) async {
    // 横屏的「同系列」和选集抽屉/视频设置同一块矩形：贴右缘、宽 1/3 屏、
    // 全高；深色底上是白字卡片，不再是一张白弹层。
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    RelatedSeries? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                picked = await RelatedSeriesSheet.showSidePanel(
                  context,
                  '1',
                  loader: (_) async => const [
                    RelatedSeries(id: '2', title: '第二季', episodeCount: 96),
                    RelatedSeries(id: '3', title: '第三季', episodeCount: 96),
                  ],
                ),
            child: const Text('同系列'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('同系列'));
    // 先起一帧让路由动画开始，再走满 200ms 滑入（否则量到的是入场位移）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    final panel = tester.getRect(
      find.byKey(const ValueKey('player-side-panel')),
    );
    expect(panel.right, closeTo(800, .5));
    expect(panel.width, closeTo(800 / 3, .5));
    expect(panel.height, closeTo(600, .5));
    expect(find.text('同系列剧'), findsOneWidget);
    final title = tester.widget<Text>(find.text('第二季'));
    expect(title.style?.color, Colors.white);
    await tester.tap(find.byKey(const ValueKey('related-series-2')));
    await tester.pumpAndSettle();
    expect(picked?.id, '2');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'embedded block reports the pick to its host instead of popping',
    (tester) async {
      // 选集弹层内嵌形态（官方 catalogdialog/view/s）：区块不自己开/关弹层，
      // 选中就把条目交给宿主的 onSelected。
      RelatedSeries? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RelatedSeriesBlock(
              seriesId: '1',
              loader: (_) async => const [
                RelatedSeries(id: '2', title: '第二季', episodeCount: 96),
              ],
              onSelected: (entry) => picked = entry,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('related-series-block')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('related-series-2')));
      await tester.pumpAndSettle();
      expect(picked?.id, '2');
      expect(
        find.byKey(const ValueKey('related-series-block')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
