import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/widgets/player/playlet_danmaku_layer.dart';
import 'package:fqapp/widgets/player/playlet_danmaku_loader.dart';

import 'support/controlled_player.dart';

/// 页面接线回归：调度器接进 PlayerPage 后，初始取数、进度预取、
/// seek 补数、切集作废与开关门禁都要按官方时机发生。
class _DanmakuFetch {
  final requests = <DanmakuFetchRequest>[];
  final calls = <Completer<PlayletCommentPage>>[];

  Future<PlayletCommentPage> call(DanmakuFetchRequest request) {
    requests.add(request);
    final completer = Completer<PlayletCommentPage>();
    calls.add(completer);
    return completer.future;
  }
}

PlayletCommentPage pageOf({
  List<PlayletComment> comments = const [],
  bool hasMore = false,
  String cursor = '',
  int nextQueryMs = 0,
}) => PlayletCommentPage(
  comments: comments,
  hasMore: hasMore,
  cursor: cursor,
  nextQueryMs: nextQueryMs,
);

PlayletComment d(String id, int offsetMs) => PlayletComment(
  id: id,
  text: '弹幕$id',
  dataType: UgcRelativeType.seriesVideo,
  offsetMs: offsetMs,
);

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 没有这个 handler，setKeepScreenOn 会留一个 10s 的超时定时器，
    // 触发测试框架的 !timersPending 检查（player_page_test 同款）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  /// 测试体内卸载页面：页面的 1s 心跳定时器必须在
  /// `!timersPending` 检查前取消，tearDown 里做已经太晚。
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
  }

  Future<void> mount(
    WidgetTester tester, {
    required _DanmakuFetch fetch,
    required List<ControlledNativePlayer> players,
    Map<String, Object> prefs = const {},
    Map<String, dynamic>? history,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() async {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          bookId: 'series-1',
          title: '剧',
          eps: [
            Chapter(itemId: 'v1', title: '第 1 集', volumeName: ''),
            Chapter(itemId: 'v2', title: '第 2 集', volumeName: ''),
          ],
          startIndex: 0,
          shortSeries: true,
          historyStore: ControlledReaderStore(entry: history),
          contentLoader: (chapter) async => {
            'video_url': 'https://example.invalid/${chapter.itemId}.mp4',
          },
          playerFactory: () => players.removeAt(0),
          danmakuFetcher: fetch.call,
        ),
      ),
    );
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('initial load then a prefetch when playback enters the batch', (
    tester,
  ) async {
    final fetch = _DanmakuFetch();
    final player = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 2);
    await mount(tester, fetch: fetch, players: [player]);

    expect(fetch.requests, hasLength(1));
    final initial = fetch.requests.single;
    expect(initial.vid, 'v1');
    expect(initial.startOffsetMs, 0);
    expect(initial.reason, DanmakuRequestReason.initial);

    fetch.calls.single.complete(
      pageOf(
        hasMore: true,
        cursor: 'c1',
        nextQueryMs: 60000,
        comments: [d('d1', 25000)],
      ),
    );
    await _flush(tester);
    final layer = tester.widget<PlayletDanmakuLayer>(
      find.byType(PlayletDanmakuLayer),
    );
    expect(layer.entries.map((e) => e.id), ['d1']);

    // 播放到首批覆盖区间内：心跳触发一次预取，之后不重复。
    player.emitPosition(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 1));
    expect(fetch.requests, hasLength(2));
    expect(fetch.requests.last.reason, DanmakuRequestReason.prefetch);
    expect(fetch.requests.last.startOffsetMs, 60000);
    expect(fetch.requests.last.cursor, 'c1');

    fetch.calls.last.complete(
      pageOf(hasMore: true, cursor: 'c2', nextQueryMs: 120000),
    );
    await _flush(tester);
    // 35s 仍在覆盖区间内（待预取点已被消费）：不再发新请求。
    player.emitPosition(const Duration(seconds: 35));
    await tester.pump(const Duration(seconds: 2));
    expect(fetch.requests, hasLength(2));
    await unmount(tester);
  });

  testWidgets('a paused drag seek refetches at the target with fresh cursor', (
    tester,
  ) async {
    final fetch = _DanmakuFetch();
    final player = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 2);
    await mount(tester, fetch: fetch, players: [player]);
    fetch.calls.single.complete(
      pageOf(hasMore: true, cursor: 'c1', nextQueryMs: 60000),
    );
    await _flush(tester);

    // 暂停中的手动 seek 仍要补数（官方暂停只停动画不停取数）。
    await player.pause();
    await _flush(tester);
    final before = fetch.requests.length;
    // 400px 宽：初始批次覆盖 [0, 60s)，拖到 x=280 -> 70% -> 84s（未覆盖）。
    // 两段 move：第一段跨过触摸阈值激活横滑，第二段送到目标位置。
    final gesture = await tester.startGesture(const Offset(100, 350));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump();
    await gesture.up();
    // 走完双击识别器的 40ms 倒计时区，避免测试结束时残留定时器。
    await tester.pump(const Duration(milliseconds: 50));
    await _flush(tester);

    final seek = fetch.requests.last;
    expect(fetch.requests.length, greaterThan(before));
    expect(seek.reason, DanmakuRequestReason.seek);
    expect(seek.startOffsetMs, 84000);
    expect(seek.cursor, '');
    await unmount(tester);
  });

  testWidgets('switching episodes drops the stale response and loads anew', (
    tester,
  ) async {
    final fetch = _DanmakuFetch();
    final first = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 2);
    final second = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 2);
    await mount(tester, fetch: fetch, players: [first, second]);

    expect(fetch.requests.single.vid, 'v1');
    // 第一集请求还在飞时播完自动切集。
    first.emitCompleted();
    await _flush(tester);

    expect(fetch.requests, hasLength(2));
    expect(fetch.requests.last.vid, 'v2');
    expect(fetch.requests.last.startOffsetMs, 0);

    // 旧集响应最后才回来：不装填、不影响新集状态。
    fetch.calls[0].complete(
      pageOf(
        hasMore: true,
        cursor: 'old',
        nextQueryMs: 60000,
        comments: [d('stale', 1000)],
      ),
    );
    await _flush(tester);
    fetch.calls[1].complete(pageOf(comments: [d('fresh', 1000)]));
    await _flush(tester);

    final layer = tester.widget<PlayletDanmakuLayer>(
      find.byType(PlayletDanmakuLayer),
    );
    expect(layer.entries.map((e) => e.id), ['fresh']);
    await unmount(tester);
  });

  testWidgets('danmaku switch gates all requests until re-enabled', (
    tester,
  ) async {
    final fetch = _DanmakuFetch();
    final player = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 2);
    await mount(
      tester,
      fetch: fetch,
      players: [player],
      prefs: const {
        'video_danmaku_switch_sp/key_enable_danmaku_by_user': false,
      },
    );
    await tester.pump(const Duration(seconds: 2));
    expect(fetch.requests, isEmpty);

    // 更多面板重新打开弹幕：立即按当前集取数。
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-more-danmaku-switch')));
    await tester.pumpAndSettle();
    expect(fetch.requests, hasLength(1));
    expect(fetch.requests.single.vid, 'v1');
    expect(fetch.requests.single.reason, DanmakuRequestReason.initial);
    await unmount(tester);
  });

  testWidgets('restored history requests danmaku at that position', (
    tester,
  ) async {
    final fetch = _DanmakuFetch();
    final player = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 2);
    await mount(
      tester,
      fetch: fetch,
      players: [player],
      history: {
        'id': 'series-1',
        'episodeId': 'v1',
        'episode': 0,
        'position': 42,
        'duration': 120,
      },
    );
    expect(fetch.requests, isNotEmpty);
    final aimed = fetch.requests.any(
      (request) => request.startOffsetMs == 42000 && request.cursor.isEmpty,
    );
    if (!aimed) {
      expect(fetch.requests.single.startOffsetMs, 0);
      fetch.calls.single.complete(pageOf(hasMore: false, nextQueryMs: 1000));
      await _flush(tester);
    }
    final target = fetch.requests.last;
    expect(target.startOffsetMs, 42000);
    expect(target.cursor, isEmpty);
    expect(
      target.reason,
      anyOf(DanmakuRequestReason.initial, DanmakuRequestReason.seek),
    );
    await unmount(tester);
  });
}
