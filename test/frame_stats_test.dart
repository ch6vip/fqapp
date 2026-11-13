import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/frame_stats.dart';

/// 一帧：`startUs` 是 vsync 起点，`uiMs` / `rasterMs` 是本帧两个线程的耗时。
FrameTiming _frame(int startUs, {double uiMs = 4, double rasterMs = 3}) {
  final ui = (uiMs * 1000).round();
  final raster = (rasterMs * 1000).round();
  final buildStart = startUs + 100;
  final buildFinish = buildStart + ui;
  final rasterStart = buildFinish + 50;
  final rasterFinish = rasterStart + raster;
  return FrameTiming(
    vsyncStart: startUs,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish + 10,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DebugPrintCallback originalDebugPrint;
  late List<String> lines;

  setUp(() {
    originalDebugPrint = debugPrint;
    lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    FrameStats.resetForTest();
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
    FrameStats.resetForTest();
  });

  int countOf(String token) =>
      lines.where((line) => line.contains(token)).length;

  test('install 幂等：重复调用只装一份采集器', () {
    FrameStats.install();
    expect(FrameStats.enabled, isTrue);
    expect(countOf('collector on'), 1);

    FrameStats.install();
    expect(countOf('collector on'), 1);
  });

  test('resetForTest 之后可以重新 install，并摘掉旧回调', () {
    FrameStats.install();
    FrameStats.resetForTest();
    expect(FrameStats.enabled, isFalse);
    expect(FrameStats.debugWindowFrames, 0);

    FrameStats.install();
    expect(FrameStats.enabled, isTrue);
    expect(countOf('collector on'), 2);

    // 新窗口只累计本轮喂进去的帧：旧回调没被摘掉就会重复累加。
    FrameStats.debugIngest([_frame(0, uiMs: 30), _frame(16000, uiMs: 30)]);
    expect(FrameStats.debugWindowFrames, 2);
  });

  test('窗口边界之后的帧归新窗口，不重复计入上一份汇总', () {
    FrameStats.install();
    FrameStats.debugIngest([_frame(0, uiMs: 20), _frame(1000000)]);
    expect(FrameStats.debugWindowFrames, 2);
    expect(countOf('frames='), 0, reason: '还没到 2 秒窗口，不该输出汇总');

    // 2100ms 越过窗口边界：先结算前两帧（其中一帧 20ms，算 jank），
    // 这一帧本身留给新窗口。
    FrameStats.debugIngest([_frame(2100000)]);
    expect(countOf('frames='), 1);
    expect(
      lines.firstWhere((l) => l.contains('frames=')),
      contains('frames=2'),
    );
    expect(FrameStats.debugWindowFrames, 1);
  });

  test('单帧超预算单独打 stall 行', () {
    FrameStats.install();
    FrameStats.debugIngest([_frame(0, uiMs: 120, rasterMs: 50)]);
    expect(countOf('stall ui=120.0 raster=50.0'), 1);
  });

  test('掉帧间隔只统计 1~8 帧，空闲长间隔不算', () {
    FrameStats.install();
    // 40ms 间隔 = 掉了约 2 帧 → 计入；320ms 属于松手后的空闲 → 不计。
    FrameStats.debugIngest([_frame(0), _frame(40000), _frame(360000)]);
    FrameStats.debugFlush();
    final summary = lines.singleWhere((l) => l.contains('frames='));
    expect(summary, contains('gaps=1'));
    expect(summary, contains('frames=3'));
  });

  test('跨窗口边界那一帧的掉帧间隔算进新窗口', () {
    FrameStats.install();
    // 窗口起点 0；第二帧 1990ms 仍在窗口内（带一帧 20ms 触发汇总输出），
    // 第三帧 2100ms 越过边界：它既是新窗口首帧，间隔 110ms 也该记进新窗口。
    FrameStats.debugIngest([_frame(0), _frame(1990000, uiMs: 20)]);
    FrameStats.debugIngest([_frame(2100000)]);
    FrameStats.debugFlush(); // 第二个窗口要显式结算

    final summaries = lines.where((l) => l.contains('frames=')).toList();
    expect(summaries.length, 2);
    expect(summaries.first, contains('frames=2'));
    expect(summaries.last, contains('frames=1'));
    expect(summaries.last, contains('gaps=1'));
  });

  test('resetForTest 之后 mark 静默', () {
    FrameStats.install();
    FrameStats.resetForTest();
    FrameStats.mark('should-not-print');
    expect(countOf('should-not-print'), 0);
  });
}
