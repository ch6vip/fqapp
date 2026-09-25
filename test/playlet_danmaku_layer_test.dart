import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_danmaku_layer.dart';

/// 弹幕时间轴的用例。
///
/// 官方规则依据 `com/dragon/community/impl/danmaku/container/l.java`：
/// 拖动进度清游标重拉（:1213-1227）、播放中预请求下一段（:1321-1328）、
/// 切集清时间线整池重灌（:1496-1528）、暂停只停动画不发请求（:1206-1208）、
/// 倍速只改渲染时长 `(横屏?12000:10000)/speed`（:1366-1380）。
void main() {
  PlayletComment danmaku(String id, int offsetMs, [String text = '前方高能']) =>
      PlayletComment(
        id: id,
        text: text,
        dataType: UgcRelativeType.seriesVideo,
        offsetMs: offsetMs,
      );

  group('DanmakuTimeline', () {
    test('a fresh timeline asks for a reload after a seek', () {
      final timeline = DanmakuTimeline();
      expect(timeline.needsReload, isTrue);
      timeline.load([danmaku('d1', 1000)]);
      expect(timeline.needsReload, isFalse);
    });

    test('loading the same episode twice de-duplicates by id', () {
      final timeline = DanmakuTimeline();
      timeline.load([danmaku('d1', 1000), danmaku('d2', 2000)]);
      timeline.load([danmaku('d2', 2000), danmaku('d3', 3000)]);
      expect(timeline.entries.map((e) => e.id), ['d1', 'd2', 'd3']);
    });

    test('entries are sorted by their millisecond offset', () {
      final timeline = DanmakuTimeline();
      timeline.load([danmaku('d2', 5000), danmaku('d1', 1000)]);
      expect(timeline.entries.map((e) => e.id), ['d1', 'd2']);
    });

    test('switching episodes clears the whole pool', () {
      final timeline = DanmakuTimeline();
      timeline.load([danmaku('d1', 1000)]);
      timeline.reset();
      expect(timeline.isEmpty, isTrue);
      expect(timeline.needsReload, isTrue, reason: '切集必须重新整池重灌');
    });

    test('only entries inside the flight window are visible', () {
      final timeline = DanmakuTimeline();
      timeline.load([danmaku('d1', 0), danmaku('d2', 5000), danmaku('d3', 9000)]);
      // 基准飞行 10000ms：9s 时 0ms 的 d1（飞了 9s）与 5s 的 d2 都在窗口内，
      // 9s 处刚出现的 d3 也还没超窗。
      expect(timeline.visibleAt(9000).map((e) => e.id), ['d1', 'd2', 'd3']);
      expect(timeline.visibleAt(-1).map((e) => e.id), isEmpty);
      expect(timeline.visibleAt(1000).map((e) => e.id), ['d1']);
    });

    test('double speed halves the flight window without refetching', () {
      final timeline = DanmakuTimeline();
      timeline.load([danmaku('d1', 0), danmaku('d2', 6000)]);
      // 8s 处：1 倍速（10000ms 窗口）两条都在；2 倍速窗口缩到 5000ms，
      // 0ms 的 d1 已经飞过窗口。
      expect(timeline.visibleAt(8000).map((e) => e.id), ['d1', 'd2']);
      expect(timeline.visibleAt(8000, rate: 2).map((e) => e.id), ['d2']);
    });

    test('a degenerate rate never divides by zero', () {
      expect(danmakuFlightMs(0), 10000);
      expect(danmakuFlightMs(-1), 10000);
      expect(danmakuFlightMs(2), 5000);
    });
  });

  group('danmaku copy and limits', () {
    test('the length hints use the official strings', () {
      expect(danmakuLengthError(5, min: 1, max: 50), '');
      expect(danmakuLengthError(51, min: 1, max: 50), '弹幕最多输入50个字');
      expect(danmakuLengthError(0, min: 1, max: 50), '弹幕最少输入1个字');
    });

    test('the toast copy matches the official switch messages', () {
      expect(danmakuEnabledToast, '弹幕已开启');
      expect(danmakuDisabledToast, '弹幕已关闭，长按视频可开启');
      expect(danmakuHint, '发条友善的弹幕吧');
    });
  });

  group('PlayletDanmakuLayer', () {
    testWidgets('renders the entries that are inside the window', (
      tester,
    ) async {
      final position = ValueNotifier<Duration>(const Duration(seconds: 1));
      addTearDown(position.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: Stack(
              children: [
                PlayletDanmakuLayer(
                  entries: [danmaku('d1', 500), danmaku('d2', 30000)],
                  position: position,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('danmaku-d1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('danmaku-d2')),
        findsNothing,
        reason: '还没到时间点的弹幕不能提前出现',
      );
    });

    testWidgets('the switch hides the whole layer', (tester) async {
      final position = ValueNotifier<Duration>(const Duration(seconds: 1));
      addTearDown(position.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: Stack(
              children: [
                PlayletDanmakuLayer(
                  entries: [danmaku('d1', 500)],
                  position: position,
                  enabled: false,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('danmaku-d1')), findsNothing);
    });
  });
}
