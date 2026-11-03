import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/audio_extra.dart';
import '../../services/audio_page_theme.dart';
import 'audio_subtitle_lines.dart';

/// Non-draggable subtitles with either compact rows or full-length cues.
class AudioSubtitleScroller extends StatefulWidget {
  const AudioSubtitleScroller({
    super.key,
    required this.track,
    required this.position,
    required this.viewportHeight,
    this.realBook = false,
    this.duration = Duration.zero,
    this.fontSize = 16,
    this.startLine = 1,
    this.statusText = '',
    this.currentLineKey = const Key('audio-subtitle-current'),
  });

  final SubtitleTrack track;
  final Duration position;
  final double viewportHeight;

  /// Compact listening-page rows, shared by both voice families. The parent
  /// supplies edge fading; row height scales with the system text size.
  final bool realBook;
  final Duration duration;
  final double fontSize;
  final int startLine;
  final String statusText;
  final Key currentLineKey;

  /// 真人讲书的固定行高（样稿）。
  static const double realRowHeight = 40;

  /// 真人讲书当前句字号（官方 `AudioPlaySubtitleView` 的 `n` 默认 20sp）。
  static const double realCurrentFontSize = 20;

  static const Curve officialCurve = _AccelerateDecelerateCurve();

  static Duration animationFor(double deltaPx) =>
      Duration(milliseconds: deltaPx.abs().truncate().clamp(300, 600));

  @override
  State<AudioSubtitleScroller> createState() => _AudioSubtitleScrollerState();
}

class _AccelerateDecelerateCurve extends Curve {
  const _AccelerateDecelerateCurve();

  @override
  double transformInternal(double t) => 0.5 - 0.5 * math.cos(math.pi * t);
}

class _AudioSubtitleScrollerState extends State<AudioSubtitleScroller>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scroll;
  Object? _layoutKey;
  SubtitleTrack _lines = SubtitleTrack.empty;
  List<double> _heights = const [];
  List<double> _offsets = const [];
  double _singleLineHeight = 0;
  double _offset = 0;
  int _shownIndex = -1;
  bool _syncing = false;

  double get _baseOffset => _singleLineHeight * (widget.startLine - 1);

  @override
  void initState() {
    super.initState();
    _scroll = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        if (_syncing) {
          _offset = _scroll.value;
        } else {
          setState(() => _offset = _scroll.value);
        }
      });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _syncLayout(
    double width,
    TextStyle style,
    TextScaler scaler,
    TextDirection direction,
    Locale? locale,
  ) {
    final key = (
      widget.track,
      width,
      style,
      scaler,
      direction,
      locale,
      widget.realBook,
      widget.duration,
    );
    final changed = _layoutKey != key;
    _syncing = true;
    try {
      if (changed) {
        _layoutKey = key;
        _lines = widget.realBook
            ? layoutInlineSubtitleLines(
                track: widget.track,
                width: width,
                style: style,
                textScaler: scaler,
                textDirection: direction,
                locale: locale,
                duration: widget.duration,
              )
            : widget.track;
        final painter = TextPainter(
          textDirection: direction,
          textScaler: scaler,
          locale: locale,
        );
        try {
          if (widget.realBook) {
            _singleLineHeight =
                AudioSubtitleScroller.realRowHeight *
                scaler.scale(widget.fontSize) /
                widget.fontSize;
            _heights = List<double>.filled(
              _lines.cues.length,
              _singleLineHeight,
            );
          } else {
            double measure(String text) {
              painter.text = TextSpan(text: text, style: style);
              painter.layout(maxWidth: width);
              return painter.height;
            }

            _singleLineHeight = measure('\u5b57');
            _heights = [for (final cue in _lines.cues) measure(cue.text)];
          }
        } finally {
          painter.dispose();
        }
        var offset = 0.0;
        _offsets = List<double>.filled(_heights.length, 0);
        for (var i = 0; i < _heights.length; i++) {
          _offsets[i] = offset;
          offset += _heights[i];
        }
      }
      final index = _lines.indexAt(widget.position);
      final target = index < 0 ? 0.0 : _offsets[index];
      if (changed || index < 0) {
        _scroll.value = target;
        _offset = target;
      } else if (index != _shownIndex) {
        // A paused seek may be the last update. Retarget in-flight animations
        // rather than depending on another player tick to catch up.
        final delta = target - _offset;
        if (delta.abs() < 0.5) {
          _scroll.value = target;
        } else {
          _scroll.animateTo(
            target,
            duration: AudioSubtitleScroller.animationFor(delta),
            curve: AudioSubtitleScroller.officialCurve,
          );
        }
      }
      _shownIndex = index;
    } finally {
      _syncing = false;
    }
  }

  int _firstRow() {
    final contentTop = _offset - _baseOffset;
    var low = 0;
    var high = _offsets.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_offsets[mid] < contentTop) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return math.max(0, low - 1);
  }

  TextStyle _textStyle(BuildContext context) {
    return DefaultTextStyle.of(context).style.copyWith(
      inherit: false,
      color: AudioPageThemeScope.of(context).ink,
      fontSize: widget.fontSize,
      fontWeight: FontWeight.w400,
      // Use font metrics, not Material body text's line/letter spacing.
      height: kTextHeightNone,
      letterSpacing: 0,
      wordSpacing: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    final style = _textStyle(context);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxWidth.isFinite || constraints.maxWidth <= 0) {
          return const SizedBox.shrink();
        }
        _syncLayout(constraints.maxWidth, style, scaler, direction, locale);
        if (_lines.isEmpty) return _statusLine(style);
        final rows = <Widget>[];
        for (var i = _firstRow(); i < _lines.cues.length; i++) {
          if (_topOf(i) >= widget.viewportHeight) break;
          rows.add(
            _rowAt(
              i,
              style: style,
              theme: theme,
              scaler: scaler,
              direction: direction,
              locale: locale,
            ),
          );
        }
        return ClipRect(
          child: ExcludeSemantics(child: Stack(children: rows)),
        );
      },
    );
  }

  double _topOf(int index) => _baseOffset + _offsets[index] - _offset;

  Widget _statusLine(TextStyle style) {
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        // 真人讲书整块有 24dp 渐隐，状态文案要避开它。
        padding: EdgeInsets.only(top: widget.realBook ? 24 : 0),
        child: Text(
          widget.statusText,
          key: const Key('audio-subtitle-status'),
          style: style,
        ),
      ),
    );
  }

  Widget _rowAt(
    int index, {
    required TextStyle style,
    required AudioPageTheme theme,
    required TextScaler scaler,
    required TextDirection direction,
    required Locale? locale,
  }) {
    final top = _topOf(index);
    final highlighted = index == _shownIndex;
    final text = Text(
      _lines.cues[index].text,
      key: highlighted ? widget.currentLineKey : null,
      style: highlighted
          ? widget.realBook
                ? style.copyWith(
                    fontSize: AudioSubtitleScroller.realCurrentFontSize,
                    fontWeight: FontWeight.w700,
                  )
                : style
          : style.copyWith(color: theme.ink.withValues(alpha: 0.4)),
      textScaler: scaler,
      textDirection: direction,
      locale: locale,
      // One cue per 40dp row; the mockup ellipsizes a long current line.
      maxLines: widget.realBook ? 1 : null,
      overflow: widget.realBook ? TextOverflow.ellipsis : null,
      softWrap: widget.realBook ? false : null,
    );
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      height: _heights[index],
      child: Align(
        // 真人讲书在 40dp 行里垂直居中（样稿 `.ln`）。
        alignment: widget.realBook ? Alignment.centerLeft : Alignment.topLeft,
        child: text,
      ),
    );
  }
}
