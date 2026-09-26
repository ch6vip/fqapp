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
      timeline.load([
        danmaku('d1', 0),
        danmaku('d2', 5000),
        danmaku('d3', 9000),
      ]);
      // 基准飞行 10000ms：9s 时 0ms 的 d1（飞了 9s）与 5s 的 d2 都在窗口内，
      // 9s 处刚出现的 d3 也还没超窗。
      expect(timeline.visibleAt(9000).map((e) => e.id), ['d1', 'd2', 'd3']);
      expect(timeline.visibleAt(-1).map((e) => e.id), isEmpty);
      expect(timeline.visibleAt(1000).map((e) => e.id), ['d1']);
    });

    test('media flight window does not apply playback speed twice', () {
      final timeline = DanmakuTimeline();
      timeline.load([danmaku('d1', 0), danmaku('d2', 6000)]);
      // 两倍速下 4s 墙钟已经是 8s 媒体时间；仍使用 10s 媒体窗口。
      expect(timeline.visibleAt(8000).map((e) => e.id), ['d1', 'd2']);
      expect(timeline.visibleAt(10000).map((e) => e.id), ['d2']);
      expect(danmakuFlightMs(2), 5000);
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
    Widget layer({
      required ValueNotifier<Duration> position,
      List<PlayletComment>? entries,
      bool playing = true,
      bool enabled = true,
      bool tickerMode = true,
      double rate = 1,
    }) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          key: const ValueKey('danmaku-viewport'),
          width: 400,
          height: 300,
          child: TickerMode(
            enabled: tickerMode,
            child: PlayletDanmakuLayer(
              entries: entries ?? [danmaku('smooth', 0)],
              position: position,
              rate: rate,
              playing: playing,
              enabled: enabled,
            ),
          ),
        ),
      ),
    );

    testWidgets('moves on each frame between native 200ms progress events', (
      tester,
    ) async {
      final position = ValueNotifier<Duration>(const Duration(seconds: 3));
      addTearDown(position.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: PlayletDanmakuLayer(
                entries: [danmaku('smooth', 0)],
                position: position,
              ),
            ),
          ),
        ),
      );
      final bubble = find.byKey(const ValueKey('danmaku-smooth'));
      final samples = [tester.getTopLeft(bubble).dx];
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        samples.add(tester.getTopLeft(bubble).dx);
      }
      debugPrint('danmaku frame positions without native ticks: $samples');
      for (var i = 1; i < samples.length; i++) {
        expect(
          samples[i],
          lessThan(samples[i - 1]),
          reason: '弹幕应逐帧移动，不能等待下一次 200ms 的原生进度事件',
        );
      }
    });

    for (final framesPerSecond in [60, 120]) {
      testWidgets(
        'native 5Hz progress keeps $framesPerSecond consecutive frames moving without rebuilding text',
        (tester) async {
          final position = ValueNotifier<Duration>(const Duration(seconds: 3));
          addTearDown(position.dispose);
          await tester.pumpWidget(layer(position: position));
          final bubble = find.byKey(const ValueKey('danmaku-smooth'));
          var previous = tester.getTopLeft(bubble).dx;
          final builds = <String, int>{};
          final oldCallback = debugOnRebuildDirtyWidget;
          debugOnRebuildDirtyWidget = (element, builtOnce) {
            final name = element.widget.runtimeType.toString();
            builds.update(name, (count) => count + 1, ifAbsent: () => 1);
          };
          addTearDown(() => debugOnRebuildDirtyWidget = oldCallback);
          final frameTime = Duration(
            microseconds: (1000000 / framesPerSecond).round(),
          );
          for (var frame = 1; frame <= framesPerSecond; frame++) {
            await tester.pump(frameTime);
            if (frame % (framesPerSecond ~/ 5) == 0) {
              position.value += const Duration(milliseconds: 200);
              await tester.pump();
            }
            final current = tester.getTopLeft(bubble).dx;
            expect(current, lessThan(previous), reason: 'frame $frame');
            expect(previous - current, lessThan(1.0));
            previous = current;
          }
          debugPrint(
            'danmaku $framesPerSecond frames, widget rebuilds: $builds',
          );
          expect(builds, isEmpty);
        },
      );
    }

    testWidgets('pause freezes and resume excludes the paused wall time', (
      tester,
    ) async {
      final position = ValueNotifier<Duration>(const Duration(seconds: 3));
      final entries = [danmaku('smooth', 0)];
      addTearDown(position.dispose);
      await tester.pumpWidget(layer(position: position, entries: entries));
      await tester.pump(const Duration(milliseconds: 100));
      final bubble = find.byKey(const ValueKey('danmaku-smooth'));
      final pausedAt = tester.getTopLeft(bubble);
      await tester.pumpWidget(
        layer(position: position, entries: entries, playing: false),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(tester.getTopLeft(bubble), pausedAt);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(layer(position: position, entries: entries));
      expect(tester.getTopLeft(bubble), pausedAt);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getTopLeft(bubble).dx, lessThan(pausedAt.dx));
      expect(pausedAt.dx - tester.getTopLeft(bubble).dx, lessThan(1));
    });

    testWidgets(
      'changing playback speed preserves position and scales motion once',
      (tester) async {
        final position = ValueNotifier<Duration>(const Duration(seconds: 3));
        final entries = [danmaku('smooth', 0)];
        addTearDown(position.dispose);
        await tester.pumpWidget(layer(position: position, entries: entries));
        final bubble = find.byKey(const ValueKey('danmaku-smooth'));
        final start = tester.getTopLeft(bubble).dx;
        await tester.pump(const Duration(milliseconds: 100));
        final atNormalRate = tester.getTopLeft(bubble).dx;
        await tester.pumpWidget(
          layer(position: position, entries: entries, rate: 2),
        );
        expect(tester.getTopLeft(bubble).dx, atNormalRate);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          atNormalRate - tester.getTopLeft(bubble).dx,
          closeTo((start - atNormalRate) * 2, .0001),
        );
        position.value = const Duration(seconds: 8);
        await tester.pump();
        expect(bubble, findsOneWidget, reason: '2x 不能把媒体窗口再次缩成 5s');
      },
    );

    testWidgets('late normal progress does not pull text backwards', (
      tester,
    ) async {
      final position = ValueNotifier<Duration>(const Duration(seconds: 3));
      addTearDown(position.dispose);
      await tester.pumpWidget(layer(position: position));
      final bubble = find.byKey(const ValueKey('danmaku-smooth'));
      await tester.pump(const Duration(milliseconds: 160));
      final beforeSample = tester.getTopLeft(bubble).dx;
      position.value = const Duration(milliseconds: 3140);
      await tester.pump();
      expect(tester.getTopLeft(bubble).dx, beforeSample);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getTopLeft(bubble).dx, lessThan(beforeSample));
    });

    testWidgets(
      'forward and backward seeks reset immediately even while paused',
      (tester) async {
        final position = ValueNotifier<Duration>(const Duration(seconds: 3));
        final entries = [danmaku('smooth', 0), danmaku('later', 20000)];
        addTearDown(position.dispose);
        await tester.pumpWidget(layer(position: position, entries: entries));
        final bubble = find.byKey(const ValueKey('danmaku-smooth'));
        final start = tester.getTopLeft(bubble);
        await tester.pump(const Duration(milliseconds: 160));
        position.value = const Duration(seconds: 21);
        await tester.pump();
        expect(bubble, findsNothing);
        expect(find.byKey(const ValueKey('danmaku-later')), findsOneWidget);
        await tester.pumpWidget(
          layer(position: position, entries: entries, playing: false),
        );
        position.value = const Duration(seconds: 3);
        await tester.pump();
        expect(tester.getTopLeft(bubble), start);
        expect(find.byKey(const ValueKey('danmaku-later')), findsNothing);
        await tester.pump(const Duration(seconds: 2));
        expect(tester.getTopLeft(bubble), start);
      },
    );

    testWidgets(
      'missing progress stops extrapolation and the next sample resumes it',
      (tester) async {
        final position = ValueNotifier<Duration>(const Duration(seconds: 3));
        addTearDown(position.dispose);
        await tester.pumpWidget(layer(position: position));
        final bubble = find.byKey(const ValueKey('danmaku-smooth'));
        final start = tester.getTopLeft(bubble).dx;
        await tester.pump(const Duration(seconds: 2));
        final stalledAt = tester.getTopLeft(bubble).dx;
        expect(stalledAt, lessThan(start));
        await tester.pump(const Duration(seconds: 2));
        expect(tester.getTopLeft(bubble).dx, stalledAt);
        expect(tester.binding.hasScheduledFrame, isFalse);
        position.value = const Duration(seconds: 6);
        await tester.pump();
        final syncedAt = tester.getTopLeft(bubble).dx;
        expect(syncedAt, lessThan(stalledAt));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(bubble).dx, lessThan(syncedAt));
      },
    );

    testWidgets(
      'muting TickerMode freezes instead of accumulating hidden time',
      (tester) async {
        final position = ValueNotifier<Duration>(const Duration(seconds: 3));
        final entries = [danmaku('smooth', 0)];
        addTearDown(position.dispose);
        await tester.pumpWidget(layer(position: position, entries: entries));
        final bubble = find.byKey(const ValueKey('danmaku-smooth'));
        await tester.pump(const Duration(milliseconds: 100));
        final beforeHidden = tester.getTopLeft(bubble);
        await tester.pumpWidget(
          layer(position: position, entries: entries, tickerMode: false),
        );
        await tester.pump(const Duration(seconds: 5));
        expect(tester.getTopLeft(bubble), beforeHidden);
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.pumpWidget(layer(position: position, entries: entries));
        expect(tester.getTopLeft(bubble), beforeHidden);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(bubble).dx, lessThan(beforeHidden.dx));
      },
    );

    testWidgets('existing comments keep their lane when an earlier one exits', (
      tester,
    ) async {
      final position = ValueNotifier<Duration>(
        const Duration(milliseconds: 9800),
      );
      addTearDown(position.dispose);
      await tester.pumpWidget(
        layer(
          position: position,
          entries: [danmaku('early', 0), danmaku('later', 2000)],
        ),
      );
      final later = find.byKey(const ValueKey('danmaku-later'));
      final laneY = tester.getTopLeft(later).dy;
      position.value = const Duration(milliseconds: 10100);
      await tester.pump();
      expect(find.byKey(const ValueKey('danmaku-early')), findsNothing);
      expect(tester.getTopLeft(later).dy, laneY);
    });

    testWidgets(
      'long text leaves the viewport with its tail before it expires',
      (tester) async {
        final position = ValueNotifier<Duration>(
          const Duration(milliseconds: 9900),
        );
        addTearDown(position.dispose);
        await tester.pumpWidget(
          layer(position: position, entries: [danmaku('long', 0, '弹幕' * 25)]),
        );
        final bubble = find.byKey(const ValueKey('danmaku-long'));
        final viewport = tester.getRect(
          find.byKey(const ValueKey('danmaku-viewport')),
        );
        expect(tester.getSize(bubble).width, greaterThan(viewport.width));
        final remainingWidth = tester.getRect(bubble).right - viewport.left;
        expect(remainingWidth, greaterThan(0));
        expect(remainingWidth, lessThan(20));
        position.value = const Duration(milliseconds: 10000);
        await tester.pump();
        expect(bubble, findsNothing);
      },
    );

    testWidgets(
      'in-place page replacement removes old comments and admits the new page',
      (tester) async {
        final position = ValueNotifier<Duration>(const Duration(seconds: 3));
        final entries = [danmaku('old', 0)];
        addTearDown(position.dispose);
        await tester.pumpWidget(layer(position: position, entries: entries));
        expect(find.byKey(const ValueKey('danmaku-old')), findsOneWidget);
        entries
          ..clear()
          ..add(danmaku('new', 1000));
        await tester.pumpWidget(layer(position: position, entries: entries));
        expect(find.byKey(const ValueKey('danmaku-old')), findsNothing);
        expect(find.byKey(const ValueKey('danmaku-new')), findsOneWidget);
      },
    );

    testWidgets(
      'disabled layers stop and position listeners detach on replacement and disposal',
      (tester) async {
        final oldPosition = _ObservedPosition(const Duration(seconds: 3));
        final position = _ObservedPosition(const Duration(seconds: 4));
        final entries = [danmaku('smooth', 0)];
        addTearDown(oldPosition.dispose);
        addTearDown(position.dispose);
        await tester.pumpWidget(layer(position: oldPosition, entries: entries));
        await tester.pumpWidget(
          layer(position: position, entries: entries, enabled: false),
        );
        await tester.pump(const Duration(seconds: 2));
        expect(find.byKey(const ValueKey('danmaku-smooth')), findsNothing);
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(oldPosition.observed, isFalse);
        position.value = const Duration(seconds: 5);
        await tester.pumpWidget(layer(position: position, entries: entries));
        expect(find.byKey(const ValueKey('danmaku-smooth')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(position.observed, isFalse);
        await tester.pump(const Duration(seconds: 2));
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(tester.takeException(), isNull);
      },
    );

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

class _ObservedPosition extends ValueNotifier<Duration> {
  _ObservedPosition(super.value);

  bool get observed => hasListeners;
}
