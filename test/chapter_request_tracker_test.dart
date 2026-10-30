import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_request_tracker.dart';

/// 预取前后章、刷新缓存与前台加载共用同一套章节请求句柄：取消必须按章
/// 隔离，否则并发预取会互相取消，刷新还会打断正在打开的章。
void main() {
  test('prefetching another chapter does not cancel an in-flight fetch', () {
    final tracker = ChapterRequestTracker();
    final first = tracker.start('chapter-1');
    final second = tracker.start('chapter-2');

    expect(first.isCancelled, isFalse);
    expect(second.isCancelled, isFalse);
    tracker.cancelAll();
  });

  test('a newer fetch supersedes only the same chapter', () {
    final tracker = ChapterRequestTracker();
    final old = tracker.start('chapter-1');
    final other = tracker.start('chapter-2');
    final next = tracker.start('chapter-1');

    expect(old.isCancelled, isTrue);
    expect(other.isCancelled, isFalse);
    expect(next.isCancelled, isFalse);
    tracker.cancelAll();
  });

  test('finishing a superseded request keeps the newer handle', () {
    final tracker = ChapterRequestTracker();
    final old = tracker.start('chapter-1');
    final next = tracker.start('chapter-1');

    tracker.finish('chapter-1', old);
    tracker.cancelAll();

    expect(next.isCancelled, isTrue, reason: '旧请求收尾不能把新句柄一起摘掉');
  });

  test('cancelAll cancels every in-flight fetch and starts clean', () {
    final tracker = ChapterRequestTracker();
    final first = tracker.start('chapter-1');
    final second = tracker.start('chapter-2');

    tracker.cancelAll();

    expect(first.isCancelled, isTrue);
    expect(second.isCancelled, isTrue);
    final next = tracker.start('chapter-1');
    expect(next.isCancelled, isFalse);
    tracker.cancelAll();
  });
}
