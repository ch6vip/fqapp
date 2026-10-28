import 'package:flutter/material.dart';

import '../../models/audio_extra.dart';
import '../../services/audio_page_theme.dart';

/// 官方 `AudioPlaySubtitleView` 的滚动语义复刻。
///
/// 取证自 `subtitle/AudioPlaySubtitleView.smali`：它**不是** ScrollView，而是
/// 在 `onDraw` 里按 `y = 基准 + v(j) - c` 逐行画（`s(Canvas,F,I,F)`），
/// 所以这里也用手绘偏移，而不是包一层 ListView——后者会用视口 padding
/// 吃掉内容区，和内联 52dp 的几何冲突。
///
/// 状态与官方一致，只有两个：
/// * `c` —— 滚动偏移（px），对应 [_offset]；
/// * `b` —— 当前行下标，由播放位置算出。
///
/// 行偏移 `v(i) = Σ_{j<i}(块高 + 间距)`，间距取官方 `k`/`m` = 16dp。
///
/// **换句动画**（`O(F,Z)`）：`ValueAnimator.ofFloat` + `setDuration`，时长
/// `clamp(|Δpx|, 300, 600) ms`（`const-wide 0x258` / `0x12c`），未设
/// Interpolator，因此是线性；`animate == false` 时直接赋值。
///
/// **惯性**（`computeScroll()` → `OverScroller.fling(...)`）：Android
/// `Scroller` 的减速曲线。[ClampingScrollSimulation] 用的正是同一条
/// （inflexion 0.35、deceleration `log(0.78)/log(0.9)`），且都不回弹。
///
/// `setScrollingSeekEnable(false)` 时（内联 52dp）不可拖动，只有自动滚动；
/// 文稿页才启用拖拽 + 飞滑，松手后按 `getIndicatePosition()`（`c + 10dp`）
/// 找最近行并 seek。
class AudioSubtitleScroller extends StatefulWidget {
  const AudioSubtitleScroller({
    super.key,
    required this.track,
    required this.position,
    required this.viewportHeight,
    this.seekEnabled = false,
    this.fontSize = 14,
    this.gap = 16,
    this.onSeek,
    this.currentLineKey = const Key('audio-inline-subtitle-current'),
  });

  final SubtitleTrack track;
  final Duration position;
  final double viewportHeight;

  /// 官方 `setScrollingSeekEnable(Z)`。
  final bool seekEnabled;

  final double fontSize;

  /// 官方 `k`/`m` = 16dp，行间留白。
  final double gap;

  /// 松手吸附后把播放位置跳到该行起点。
  final ValueChanged<Duration>? onSeek;

  /// 当前行的 key，供调用方按语义区分（内联槽 / 文稿面板）。
  final Key currentLineKey;

  /// 换句动画时长：`clamp(|Δpx|, 300, 600)`，与官方一致。
  static Duration animationFor(double deltaPx) {
    final ms = deltaPx.abs().round().clamp(300, 600);
    return Duration(milliseconds: ms);
  }

  /// 官方普通行色 `@color/agw` = `#66ffffff`。
  static const Color contextInk = Color(0x66FFFFFF);

  @override
  State<AudioSubtitleScroller> createState() => _AudioSubtitleScrollerState();
}

class _AudioSubtitleScrollerState extends State<AudioSubtitleScroller>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scroll = AnimationController.unbounded(
    vsync: this,
  )..addListener(_onTick);

  double _offset = 0;
  List<double> _heights = const [];
  double _width = 0;
  int _shownIndex = -1;

  /// build 期间同步控制器内部值时置位，避免在 build 里 setState。
  bool _syncing = false;

  @override
  void didUpdateWidget(covariant AudioSubtitleScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = widget.track.indexAt(widget.position);
    if (index >= 0 && index != _shownIndex && !_scroll.isAnimating) {
      _shownIndex = index;
      _centerOn(index);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onTick() {
    if (_syncing) {
      _offset = _scroll.value;
      return;
    }
    setState(() => _offset = _scroll.value);
  }

  /// 行顶部在内容坐标系里的位置。
  double _offsetOf(int index) {
    var value = 0.0;
    for (var i = 0; i < index && i < _heights.length; i++) {
      value += _heights[i] + widget.gap;
    }
    return value;
  }

  /// 让第 [index] 行压在视口垂直中心所需的内容偏移。
  double _centerOf(int index) {
    if (index < 0 || index >= _heights.length) return 0;
    return _offsetOf(index) + _heights[index] / 2;
  }

  double get _minOffset =>
      _heights.isEmpty ? 0 : _heights.first / 2;

  double get _maxOffset =>
      _heights.isEmpty ? 0 : _centerOf(_heights.length - 1);

  double _clampOffset(double value) =>
      value.clamp(_minOffset, _maxOffset);

  /// `O(F,Z)`：线性动画，时长按位移取 300–600ms。
  void _centerOn(int index) {
    final target = _clampOffset(_centerOf(index));
    final delta = target - _offset;
    if (delta.abs() < 0.5) return;
    _scroll.animateTo(
      target,
      duration: AudioSubtitleScroller.animationFor(delta),
      curve: Curves.linear,
    );
  }

  /// `computeScroll()` + `OverScroller.fling`：Android 减速曲线。
  void _fling(double velocity) {
    _scroll.animateWith(
      ClampingScrollSimulation(
        position: _offset,
        velocity: velocity,
        tolerance: Tolerance.defaultTolerance,
      ),
    );
  }

  /// 松手吸附到最近行，并把播放位置跳到那一行（`getIndicatePosition()`）。
  void _snapToNearestLine() {
    if (_heights.isEmpty) return;
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < _heights.length; i++) {
      final distance = (_centerOf(i) - _offset).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    _centerOn(best);
    if (best < widget.track.cues.length) {
      widget.onSeek
          ?.call(Duration(milliseconds: widget.track.cues[best].startMs));
    }
  }

  TextStyle _style(BuildContext context, {required bool highlighted}) {
    final theme = AudioPageThemeScope.of(context);
    return TextStyle(
      color: highlighted ? theme.ink : AudioSubtitleScroller.contextInk,
      fontSize: widget.fontSize,
      height: 1.35,
      fontWeight: highlighted ? FontWeight.w600 : FontWeight.w400,
    );
  }

  /// 用与渲染完全相同的样式测量行高，保证偏移和绘制一致。
  List<double> _measure(BuildContext context, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    return [
      for (final cue in widget.track.cues)
        _heightOf(context, cue.text, width, scaler),
    ];
  }

  double _heightOf(
    BuildContext context,
    String text,
    double width,
    TextScaler scaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _style(context, highlighted: false)),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 3,
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// 数据或宽度变化后重新测量，并把视图定位到当前句。
  void _remeasureIfNeeded(BuildContext context, double width) {
    if (width == _width && _heights.length == widget.track.cues.length) return;
    _width = width;
    _heights = _measure(context, width);
    final index = widget.track.indexAt(widget.position);
    _shownIndex = index;
    final target = index < 0 ? 0.0 : _clampOffset(_centerOf(index));
    _syncing = true;
    _scroll.value = target;
    _syncing = false;
    _offset = target;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _remeasureIfNeeded(context, constraints.maxWidth);
        final index = widget.track.indexAt(widget.position);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: widget.seekEnabled
              ? (_) => _scroll.stop()
              : null,
          onVerticalDragUpdate: widget.seekEnabled
              ? (details) {
                  // 1:1 跟手，与官方 `c -= dy` 一致，不外扩回弹。
                  setState(() {
                    _offset = _clampOffset(_offset - details.delta.dy);
                  });
                }
              : null,
          onVerticalDragEnd: widget.seekEnabled
              ? (details) {
                  final velocity = -details.velocity.pixelsPerSecond.dy;
                  if (velocity.abs() > 50) {
                    _fling(velocity);
                  } else {
                    _snapToNearestLine();
                  }
                }
              : null,
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: Transform.translate(
                    offset: Offset(0, widget.viewportHeight / 2 - _offset),
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < widget.track.cues.length; i++)
                            SizedBox(
                              height: _heights[i],
                              width: double.infinity,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  widget.track.cues[i].text,
                                  key: i == index
                                      ? widget.currentLineKey
                                      : null,
                                  maxLines: 3,
                                  style: _style(
                                    context,
                                    highlighted: i == index,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
