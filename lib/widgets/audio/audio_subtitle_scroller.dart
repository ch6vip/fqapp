import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/audio_extra.dart';
import '../../services/audio_page_theme.dart';

/// 官方 `AudioPlaySubtitleView` 的绘制与换句动画复刻。
///
/// 取证自 `subtitle/AudioPlaySubtitleView.smali`：它**不是** ScrollView，而是在
/// `onDraw` 里逐行自绘，屏幕坐标 `y = base + v(j) + 10dp - c`：
///
/// * `v(i) = Σ_{j<i}(x(j) + y(j))`，其中 `x(i) = e + f = 10dp + 10dp = 20dp`
///   是行间留白，`y(i) = n*(descent-ascent) + leading` 是文本块高。
///   （注意：字段 `k`/`m` = 16dp 是**字号**，不是行距。）
/// * `base = (l + x(0)) * (startLine - 1)`，而 `l`
///   （`setNormalSingleLineHeight`）全仓库无调用者恒为 0，所以内联的
///   `startLine = 1` 使 `base = 0`——**当前句行顶落在视口 10dp 处**，
///   上方已读句被裁到视口外。官方全程没有居中公式。
/// * `c` 是内容偏移，`R(I,Z)` 把它置为 `v(当前行)`。
///
/// **官方这一版不可拖动**：`setScrollingSeekEnable` 只被调用两次，
/// `header/m0`（内联）与 `subtitle/x0`（文稿页）**都传 false**，
/// `onTouchEvent` 第一句就是 `if (!q) return`。所以这里不实现拖拽/飞滑，
/// 只做自动换句动画——多出来的交互反而是与官方不一致。
///
/// **换句动画**（`O(F,Z)`）：`ValueAnimator.ofFloat([c, v(index)])`，
/// 时长 `clamp(trunc(|Δ|), 300, 600) ms`；没调 `setInterpolator`，因此用的是
/// Android `ValueAnimator` 的默认插值器 `AccelerateDecelerateInterpolator`
/// ——即余弦 ease-in-out `0.5 - 0.5*cos(πt)`，**不是线性**。
class AudioSubtitleScroller extends StatefulWidget {
  const AudioSubtitleScroller({
    super.key,
    required this.track,
    required this.position,
    required this.viewportHeight,
    this.fontSize = 16,
    this.statusText = '',
    this.currentLineKey = const Key('audio-inline-subtitle-current'),
  });

  final SubtitleTrack track;
  final Duration position;
  final double viewportHeight;

  /// 官方默认字号 16sp（`bo2.o.l()`，跟随用户字号设置）。
  final double fontSize;

  /// 无字幕时的状态文案（官方 `setStatusText`）；空串表示不显示。
  final String statusText;

  /// 当前行的 key，供调用方按语义区分（内联槽 / 文稿面板）。
  final Key currentLineKey;

  /// 行间距：官方 `x(i) = e + f = 10dp + 10dp`。
  static const double lineGap = 20;

  /// 官方 `y0.m()`：每行文本块顶部的固定留白。
  static const double lineTopInset = 10;

  /// 官方普通行色 `@color/agw` = `#66ffffff`。
  static const Color contextInk = Color(0x66FFFFFF);

  /// 官方 `AccelerateDecelerateInterpolator`。
  static const Curve officialCurve = _AccelerateDecelerateCurve();

  /// 换句动画时长：`clamp(trunc(|Δpx|), 300, 600)` 毫秒。
  static Duration animationFor(double deltaPx) {
    final ms = deltaPx.abs().truncate().clamp(300, 600);
    return Duration(milliseconds: ms);
  }

  @override
  State<AudioSubtitleScroller> createState() => _AudioSubtitleScrollerState();
}

/// Android `AccelerateDecelerateInterpolator`：`cos((t+1)π)/2 + 0.5`。
class _AccelerateDecelerateCurve extends Curve {
  const _AccelerateDecelerateCurve();

  @override
  double transformInternal(double t) => 0.5 - 0.5 * math.cos(math.pi * t);
}

class _AudioSubtitleScrollerState extends State<AudioSubtitleScroller>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scroll;

  @override
  void initState() {
    super.initState();
    // 必须在这里创建：空轨道时 build 会提前返回，`late` 惰性初始化会拖到
    // dispose 里才触发，导致在已卸载的元素上查找 TickerMode 而崩溃。
    _scroll = AnimationController.unbounded(vsync: this)
      ..addListener(_onTick);
  }

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
      _animateTo(index);
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

  /// 行顶部在内容坐标系里的位置：`v(i) = Σ_{j<i}(块高 + 20dp)`。
  double _offsetOf(int index) {
    var value = 0.0;
    for (var i = 0; i < index && i < _heights.length; i++) {
      value += _heights[i] + AudioSubtitleScroller.lineGap;
    }
    return value;
  }

  double get _maxOffset =>
      _heights.isEmpty ? 0 : _offsetOf(_heights.length - 1);

  /// `R(I,Z)` + `O(F,Z)`：动画到 `c = v(index)`，余弦缓动，300–600ms。
  void _animateTo(int index) {
    final target = _offsetOf(index).clamp(0.0, _maxOffset);
    final delta = target - _offset;
    if (delta.abs() < 0.5) return;
    _scroll.animateTo(
      target,
      duration: AudioSubtitleScroller.animationFor(delta),
      curve: AudioSubtitleScroller.officialCurve,
    );
  }

  TextStyle _style(BuildContext context, {required bool highlighted}) {
    final theme = AudioPageThemeScope.of(context);
    // 官方当前行只 `setTypeface(Typeface.DEFAULT)`，不加粗。
    return TextStyle(
      color: highlighted ? theme.ink : AudioSubtitleScroller.contextInk,
      fontSize: widget.fontSize,
    );
  }

  /// 用与渲染完全相同的样式测量块高（官方 `y(i)` 来自字体度量）。
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
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// 数据或宽度变化后重新测量，并把 `c` 直接置到当前行（官方同步赋值分支）。
  void _remeasureIfNeeded(BuildContext context, double width) {
    if (width == _width && _heights.length == widget.track.cues.length) return;
    _width = width;
    _heights = _measure(context, width);
    final index = widget.track.indexAt(widget.position);
    _shownIndex = index;
    final target = index < 0 ? 0.0 : _offsetOf(index).clamp(0.0, _maxOffset);
    _syncing = true;
    _scroll.value = target;
    _syncing = false;
    _offset = target;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (widget.track.isEmpty) {
          // 官方 LOADING / ERROR / OFFLINE_LIMIT 走 `setStatusText`，槽位保留。
          return Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(
                top: AudioSubtitleScroller.lineTopInset,
              ),
              child: Text(
                widget.statusText,
                key: const Key('audio-inline-subtitle-status'),
                style: TextStyle(
                  color: AudioSubtitleScroller.contextInk,
                  fontSize: widget.fontSize,
                ),
              ),
            ),
          );
        }
        _remeasureIfNeeded(context, constraints.maxWidth);
        final index = widget.track.indexAt(widget.position);
        return ClipRect(
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Transform.translate(
                  // 官方：`y = base(=0) + v(j) + 10dp - c`。
                  offset: Offset(
                    0,
                    AudioSubtitleScroller.lineTopInset - _offset,
                  ),
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < widget.track.cues.length; i++)
                          SizedBox(
                            // 块高之后再加 20dp 行距（官方 `x(i)`）。
                            height: _heights[i] +
                                AudioSubtitleScroller.lineGap,
                            width: double.infinity,
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Text(
                                widget.track.cues[i].text,
                                key: i == index ? widget.currentLineKey : null,
                                style: _style(context, highlighted: i == index),
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
        );
      },
    );
  }
}
