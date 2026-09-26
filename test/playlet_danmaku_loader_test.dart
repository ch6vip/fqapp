import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/player/playlet_danmaku_layer.dart';
import 'package:fqapp/widgets/player/playlet_danmaku_loader.dart';

/// 调度器行为回归：预取链、seek 补数、竞态作废、重试预算与生命周期。
/// 官方依据见 docs/validation/short-drama-danmaku-prefetch-20260927.md。
class _ControlledFetch {
  final requests = <DanmakuFetchRequest>[];
  final calls = <Completer<PlayletCommentPage>>[];

  Future<PlayletCommentPage> call(DanmakuFetchRequest request) {
    requests.add(request);
    final completer = Completer<PlayletCommentPage>();
    calls.add(completer);
    return completer.future;
  }

  void serve(int index, PlayletCommentPage page) => calls[index].complete(page);

  void fail(int index) => calls[index].completeError(_Boom());
}

class _Boom implements Exception {
  const _Boom();
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

void main() {
  late _ControlledFetch fetch;
  late DanmakuLoader loader;
  final loadedPages = <List<PlayletComment>>[];

  setUp(() {
    fetch = _ControlledFetch();
    loadedPages.clear();
    loader = DanmakuLoader(fetch: fetch.call, onLoad: loadedPages.add);
  });

  test('initial batch starts the prefetch chain at the covered end', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      expect(fetch.requests.single.vid, 'v1');
      expect(fetch.requests.single.startOffsetMs, 0);
      expect(fetch.requests.single.cursor, '');
      expect(
        fetch.requests.single.reason,
        DanmakuRequestReason.initial,
      );

      fetch.serve(
        0,
        pageOf(
          hasMore: true,
          cursor: 'c1',
          nextQueryMs: 60000,
          comments: [d('d1', 59000)],
        ),
      );
      async.flushMicrotasks();
      expect(loadedPages.single.map((e) => e.id), ['d1']);

      // 进度进入首批覆盖区间 -> 立刻按区间右端预取下一批（官方 C()）。
      loader.onProgress(1000);
      expect(fetch.requests.last.reason, DanmakuRequestReason.prefetch);
      expect(fetch.requests.last.startOffsetMs, 60000);
      expect(fetch.requests.last.cursor, 'c1');

      // 同一覆盖区间内的进度不再触发请求。
      final count = fetch.requests.length;
      loader.onProgress(30000);
      loader.onProgress(59000);
      expect(fetch.requests.length, count);

      fetch.serve(1, pageOf(hasMore: true, cursor: 'c2', nextQueryMs: 120000));
      async.flushMicrotasks();
      loader.onProgress(61000);
      expect(fetch.requests.last.startOffsetMs, 120000);
      expect(fetch.requests.last.cursor, 'c2');
    });
  });

  test('progress inside a covered interval never re-requests it', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      fetch.serve(0, pageOf(hasMore: true, cursor: 'c1', nextQueryMs: 90000));
      async.flushMicrotasks();
      // 覆盖 [0, 90s)：区间内反复心跳不请求；进入区间也只预取一次。
      for (final ms in const [0, 1000, 45000, 89999]) {
        loader.onProgress(ms);
      }
      expect(fetch.requests.length, 2); // initial + 一次预取
      expect(fetch.requests.last.startOffsetMs, 90000);
    });
  });

  test('hasMore=false stops prefetch and refills until a seek resets it', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      fetch.serve(0, pageOf(hasMore: false, cursor: 'c1', nextQueryMs: 60000));
      async.flushMicrotasks();
      loader.onProgress(61000);
      loader.onProgress(90000);
      expect(fetch.requests.length, 1);
      // seek 重置 hasMore（官方 ON_SEEK_FINISH 的 i.set(true)）。
      loader.onSeek(90000);
      expect(fetch.requests.last.reason, DanmakuRequestReason.seek);
      expect(fetch.requests.last.startOffsetMs, 90000);
      expect(fetch.requests.last.cursor, '');
    });
  });

  test('a seek onto covered data is skipped', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      fetch.serve(0, pageOf(hasMore: true, cursor: 'c1', nextQueryMs: 60000));
      async.flushMicrotasks();
      final count = fetch.requests.length;
      loader.onSeek(30000);
      loader.onSeek(0);
      expect(fetch.requests.length, count);
    });
  });

  test('rapid seeks collapse to the newest target after the in-flight call', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      loader.onSeek(30000);
      loader.onSeek(45000);
      loader.onSeek(50000);
      expect(fetch.requests, hasLength(1)); // 单飞：后续只排队
      fetch.serve(0, pageOf(hasMore: true, cursor: 'c1', nextQueryMs: 60000));
      async.flushMicrotasks();
      expect(fetch.requests, hasLength(2));
      expect(fetch.requests.last.reason, DanmakuRequestReason.seek);
      expect(fetch.requests.last.startOffsetMs, 50000);
      expect(fetch.requests.last.cursor, '');
    });
  });

  test('a queued seek is not replaced by a progress refill', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      loader.onSeek(45000);
      loader.onProgress(70000); // 未覆盖，但排队的 seek 更重要
      fetch.serve(0, pageOf(hasMore: true, cursor: 'c1', nextQueryMs: 60000));
      async.flushMicrotasks();
      expect(fetch.requests.last.reason, DanmakuRequestReason.seek);
      expect(fetch.requests.last.startOffsetMs, 45000);
    });
  });

  test('switching videos invalidates the in-flight response', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      loader.reset(vid: 'v2');
      expect(fetch.requests, hasLength(2));
      expect(fetch.requests.last.vid, 'v2');
      // 旧视频的响应迟到：不能装填、不能记覆盖区间。
      fetch.serve(
        0,
        pageOf(hasMore: true, cursor: 'old', nextQueryMs: 60000, comments: [
          d('old', 1000),
        ]),
      );
      async.flushMicrotasks();
      expect(loadedPages, isEmpty);
      // 新视频请求仍能正常收尾（单飞标志没有被旧响应破坏）。
      fetch.serve(1, pageOf(hasMore: false, comments: [d('new', 1000)]));
      async.flushMicrotasks();
      expect(loadedPages.single.map((e) => e.id), ['new']);
    });
  });

  test('failures retry with a delay and a bounded budget', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      // 官方预算 8 次：首批 + 7 次重试，第 8 次失败后停。
      for (var attempt = 1; attempt <= 8; attempt++) {
        fetch.fail(attempt - 1);
        async.flushMicrotasks();
        if (attempt < 8) {
          async.elapse(const Duration(milliseconds: 999));
          expect(fetch.requests.length, attempt, reason: '不足 1s 不重试');
          async.elapse(const Duration(milliseconds: 1));
          expect(fetch.requests.length, attempt + 1, reason: '1s 后重试');
        } else {
          async.elapse(const Duration(seconds: 5));
          expect(fetch.requests.length, 8, reason: '预算用尽后不再重试');
        }
      }
      // 预算用尽后 seek 仍有一条活路（重置预算），失败重试一次。
      loader.onSeek(20000);
      expect(fetch.requests.length, 9);
      fetch.serve(8, pageOf(hasMore: false));
      async.flushMicrotasks();
      // 成功会重置预算：再来一次失败照样重试。
      loader.onSeek(30000);
      expect(fetch.requests.length, 10);
      fetch.fail(9);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(fetch.requests.length, 11);
      expect(fetch.requests.last.startOffsetMs, 30000);
    });
  });

  test('a seek gets a fresh retry budget even after exhaustion', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      for (var attempt = 1; attempt <= 8; attempt++) {
        fetch.fail(attempt - 1);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
      }
      expect(fetch.requests.length, 8);
      // seek 重置预算与 hasMore：失败的目标仍按官方清游标重拉。
      loader.onSeek(45000);
      expect(fetch.requests.length, 9);
      fetch.fail(8);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(fetch.requests.length, 10);
      expect(fetch.requests.last.startOffsetMs, 45000);
    });
  });

  test('disabled loader sends nothing and drops queued work', () {
    fakeAsync((async) {
      loader.setEnabled(false);
      loader.reset(vid: 'v1');
      loader.onSeek(30000);
      loader.onProgress(70000);
      expect(fetch.requests, isEmpty);

      loader.setEnabled(true);
      // 已覆盖处仍不请求；未覆盖处恢复取数。
      loader.reset(vid: 'v1');
      fetch.serve(0, pageOf(hasMore: true, cursor: 'c1', nextQueryMs: 60000));
      async.flushMicrotasks();
      // 重新开启后进入覆盖区间：先按官方语义预取一次下一段。
      loader.onProgress(30000);
      expect(fetch.requests, hasLength(2));
      fetch.serve(1, pageOf(hasMore: true, cursor: 'c2', nextQueryMs: 120000));
      async.flushMicrotasks();
      final count = fetch.requests.length;
      loader.onProgress(30000);
      expect(fetch.requests.length, count);
      loader.onProgress(61000);
      expect(fetch.requests.length, greaterThan(count));
    });
  });

  test('disabling mid-flight cancels the retry timer', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      fetch.fail(0);
      async.flushMicrotasks();
      loader.setEnabled(false);
      async.elapse(const Duration(seconds: 5));
      expect(fetch.requests.length, 1);
    });
  });

  test('dispose silences everything', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      loader.dispose();
      fetch.serve(0, pageOf(hasMore: true, cursor: 'c', nextQueryMs: 60000));
      async.flushMicrotasks();
      expect(loadedPages, isEmpty);
      loader.onProgress(61000);
      loader.onSeek(70000);
      loader.reset(vid: 'v2');
      expect(fetch.requests.length, 1);
    });
  });

  test('missing nextQueryMs only covers the current second', () {
    fakeAsync((async) {
      loader.reset(vid: 'v1');
      // 证据缺口兜底：回包缺 next_query_danmaku_list_time 时只盖当前秒，
      // 后续靠 cursor 续拉，宁可多问不可漏弹幕。
      fetch.serve(0, pageOf(hasMore: true, cursor: 'c1'));
      async.flushMicrotasks();
      loader.onProgress(500);
      expect(fetch.requests.length, 1);
      loader.onProgress(1500);
      expect(fetch.requests.last.reason, DanmakuRequestReason.progressRefill);
      expect(fetch.requests.last.startOffsetMs, 1500);
      expect(fetch.requests.last.cursor, 'c1');
    });
  });

  test('the timeline merges pages and dedupes by danmaku id', () {
    final timeline = DanmakuTimeline();
    timeline.load([d('a', 30000), d('b', 10000)]);
    timeline.load([d('b', 10000), d('c', 20000)]);
    expect(timeline.entries.map((e) => e.id), ['b', 'c', 'a']);
    expect(timeline.entries.map((e) => e.offsetMs), [10000, 20000, 30000]);
  });
}
