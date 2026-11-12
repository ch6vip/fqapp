import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Frame-time sampling for diagnosing jank on a real device.
///
/// `logcat` alone cannot tell Flutter's UI-thread time from its raster-thread
/// time, and `dumpsys gfxinfo` only counts one frame for a `FlutterView`
/// (verified on the test phone: `Total frames rendered: 1` while the app was
/// scrolling). The engine's own [FrameTiming] is the only source that splits
/// `buildDuration` from `rasterDuration`, so this collector aggregates it and
/// prints one line per window through [debugPrint], which lands in logcat
/// under the `flutter` tag.
///
/// Debug/profile only: release builds never install it, so it cannot cost
/// anything in a shipped build. The window is deliberately short and the
/// output is one line, so reading it back from `adb logcat -d` stays easy.
///
/// Reading the output:
/// * `ui` = Dart build/layout/paint time on the UI thread.
/// * `raster` = engine raster time on the raster thread.
/// * `gap` = frames whose vsync interval exceeded 1.5 budgets, i.e. frames
///   that were skipped entirely (no [FrameTiming] is reported for those).
class FrameStats {
  FrameStats._();

  /// 60Hz budget. The phone reports a 16.67ms app cadence even on a 120Hz
  /// panel, so a longer interval is a dropped frame regardless of the panel.
  static const double budgetMs = 16.7;

  static const Duration window = Duration(seconds: 2);

  static const String tag = 'FqPerf';

  /// 单帧超过这个时长就单独打一行：排查「偶发一两百毫秒」的停顿时需要知道
  /// 它发生在哪一刻，聚合行做不到。
  static const double stallMs = 40;

  static bool _installed = false;
  static final List<FrameTiming> _frames = <FrameTiming>[];
  static int? _windowStartUs;
  static int? _lastVsyncUs;
  static int _gapCount = 0;
  static double _worstGapMs = 0;

  /// Installs the collector once. No-op in release builds.
  ///
  /// 汇总靠帧时间戳判定窗口满没满，**不用 Timer**：定时器在 widget 测试的
  /// fake async 里会以「pending timer」收尾失败，而这个采集器在 debug 构建
  /// 的每个入口都会装一次。
  static void install() {
    if (_installed || kReleaseMode) return;
    _installed = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    debugPrint('$tag collector on (budget=${budgetMs}ms)');
  }

  /// 采集器是否在工作（debug/profile 且已安装）。release 恒假，
  /// 调用方可以据此跳过自己那点测量开销。
  static bool get enabled => _installed;

  static void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final start = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      final ui = _ms(timing.buildDuration);
      final raster = _ms(timing.rasterDuration);
      if (ui > stallMs || raster > stallMs) {
        debugPrint(
          '$tag stall ui=${ui.toStringAsFixed(1)} '
          'raster=${raster.toStringAsFixed(1)}',
        );
      }
      final windowStart = _windowStartUs;
      if (windowStart == null) {
        _windowStartUs = start;
      } else if (start - windowStart >= window.inMicroseconds) {
        // 先结算上一窗口，再让这一帧成为新窗口的第一帧：否则边界之后的
        // 帧会被算进旧窗口（每 2 秒最多一批的归属偏差）。
        _flush();
        _windowStartUs = start;
      }
      _frames.add(timing);
      final last = _lastVsyncUs;
      _lastVsyncUs = start;
      if (last == null) continue;
      final gapMs = (start - last) / 1000.0;
      // 只统计「掉 1~8 帧」的间隔。更长的间隔基本是用户松手后的空闲，
      // 把它算成掉帧会让一次滑动看起来像丢了四十多帧。
      if (gapMs > budgetMs * 1.5 && gapMs <= budgetMs * 9) {
        _gapCount++;
        if (gapMs > _worstGapMs) _worstGapMs = gapMs;
      }
    }
  }

  /// 在业务关键路径上打一个时间点，和 `stall` 行按 logcat 时间戳对齐。
  ///
  /// debug/profile 才有输出；release 里 [install] 不会执行，这里直接空转。
  static void mark(String label) {
    if (!_installed) return;
    debugPrint('$tag mark $label');
  }

  static void _flush() {
    final frames = List<FrameTiming>.of(_frames);
    _frames.clear();
    final gaps = _gapCount;
    final worstGap = _worstGapMs;
    _gapCount = 0;
    _worstGapMs = 0;
    if (frames.isEmpty && gaps == 0) return;

    final ui = [for (final f in frames) _ms(f.buildDuration)]..sort();
    final raster = [for (final f in frames) _ms(f.rasterDuration)]..sort();
    final jank = [
      for (final f in frames)
        if (_ms(f.buildDuration) > budgetMs || _ms(f.rasterDuration) > budgetMs)
          f,
    ].length;
    // 有真实动画在跑（>=8 帧）就输出一行，哪怕零掉帧：否则「很流畅」与
    // 「采集器没工作」在日志里长得一模一样。
    if (jank == 0 && gaps == 0 && frames.length < 8) return;

    debugPrint(
      '$tag frames=${frames.length} jank=$jank gaps=$gaps '
      'ui(p50/p90/max)=${_p50(ui).toStringAsFixed(1)}/'
      '${_p90(ui).toStringAsFixed(1)}/${_max(ui).toStringAsFixed(1)} '
      'raster(p50/p90/max)=${_p50(raster).toStringAsFixed(1)}/'
      '${_p90(raster).toStringAsFixed(1)}/${_max(raster).toStringAsFixed(1)} '
      'worstGap=${worstGap.toStringAsFixed(1)}ms',
    );
  }

  static double _ms(Duration value) => value.inMicroseconds / 1000.0;

  /// 直接把一批帧喂给采集器（不经 `PlatformDispatcher`），供单测验证窗口
  /// 切分与聚合口径。release 里显式空转，避免调试入口被误用到线上路径。
  @visibleForTesting
  static void debugIngest(List<FrameTiming> timings) {
    if (kReleaseMode) return;
    _onTimings(timings);
  }

  @visibleForTesting
  static void debugFlush() {
    if (kReleaseMode) return;
    _flush();
  }

  /// 当前窗口里已累计的帧数。
  @visibleForTesting
  static int get debugWindowFrames => _frames.length;

  static double _p50(List<double> sorted) =>
      sorted.isEmpty ? 0 : sorted[sorted.length ~/ 2];

  static double _p90(List<double> sorted) =>
      sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * 0.9).round()];

  static double _max(List<double> sorted) => sorted.isEmpty ? 0 : sorted.last;

  @visibleForTesting
  static void resetForTest() {
    // 摘掉回调，否则紧跟着的 install() 会再注册一份，每批帧被统计两次。
    // 只有确实装着才能摘：`removeTimingsCallback` 对不存在的回调会断言。
    if (_installed) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    }
    _frames.clear();
    _windowStartUs = null;
    _lastVsyncUs = null;
    _gapCount = 0;
    _worstGapMs = 0;
    _installed = false;
  }
}
