import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/audio_time_track.dart';
import '../../services/audio_page_theme.dart';
import '../../services/chapter_text_formatter.dart';
import '../home/home_design.dart';

/// 展开态：页内整章正文（样稿「展开态」）。
///
/// 238dp 字幕区换成本章全文：段首缩进 2 字，字号/行距跟随阅读器排版
/// 设置，当前朗读词用 accent 10%（深色 14%）底色标出；播放位置跨段时
/// 自动滚动到正在读的那一段。上下分别渐隐 40dp / 48dp。
class AudioRealExpandedTranscript extends StatefulWidget {
  /// 展开/收起过渡（样稿：300ms，`PathInterpolator(0.42, 0, 0.58, 1)`）。
  static const transitionDuration = Duration(milliseconds: 300);
  static const transitionCurve = Cubic(0.42, 0, 0.58, 1);

  /// 正文上下渐隐高度（规格 S6）。
  static const topFade = 40.0;
  static const bottomFade = 48.0;

  static const horizontalPadding = 20.0;

  /// 段间距（样稿 `.tx p { margin: 0 0 18px }`）。
  static const paragraphSpacing = 18.0;

  /// 取不到阅读器排版设置时的兜底（规格 S6）。
  static const fallbackFontSize = 20.0;
  static const fallbackLineHeight = 2.1;

  /// 当前词高亮：accent 10%，深色 14%（样稿 `--hl`）。
  static const lightHighlightAlpha = 0.10;
  static const darkHighlightAlpha = 0.14;

  final ChapterContent content;

  /// 原著章节标题：非空时剥掉正文开头的同名标题段。
  final String chapterTitle;

  final AudioTimeTrack timeTrack;
  final Duration position;

  /// 正文字号 / 行高，来自 [ReaderPreferences] 或兜底。
  final double fontSize;
  final double lineHeight;

  /// 深色外观决定高亮透明度。
  final bool dark;

  const AudioRealExpandedTranscript({
    super.key,
    required this.content,
    this.chapterTitle = '',
    required this.timeTrack,
    required this.position,
    this.fontSize = fallbackFontSize,
    this.lineHeight = fallbackLineHeight,
    this.dark = false,
  });

  @override
  State<AudioRealExpandedTranscript> createState() =>
      _AudioRealExpandedTranscriptState();
}

typedef _WordHighlight = ({int index, int start, int end});

class _AudioRealExpandedTranscriptState
    extends State<AudioRealExpandedTranscript> {
  final ScrollController _scroll = ScrollController();
  List<ChapterParagraph> _paragraphs = const [];
  List<GlobalKey> _paragraphKeys = const [];
  Object? _paragraphsSource;
  String _paragraphsTitle = '';
  int _followedIndex = -1;
  bool _followScheduled = false;
  bool _firstFollow = true;

  @override
  void initState() {
    super.initState();
    _syncParagraphs();
  }

  @override
  void didUpdateWidget(AudioRealExpandedTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.content, widget.content) ||
        oldWidget.chapterTitle != widget.chapterTitle) {
      _syncParagraphs();
      _followedIndex = -1;
      _firstFollow = true;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 正文只保留有字的段落；开头的章名段与书籍行重复，取到标题就剥掉。
  void _syncParagraphs() {
    if (identical(widget.content, _paragraphsSource) &&
        widget.chapterTitle == _paragraphsTitle) {
      return;
    }
    _paragraphsSource = widget.content;
    _paragraphsTitle = widget.chapterTitle;
    final body = widget.chapterTitle.trim().isEmpty
        ? widget.content
        : widget.content.withoutLeadingTitle(widget.chapterTitle);
    _paragraphs = [
      for (final block in body.blocks)
        if (block is ChapterParagraph && block.text.trim().isNotEmpty) block,
    ];
    _paragraphKeys = [for (var i = 0; i < _paragraphs.length; i++) GlobalKey()];
  }

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    if (_paragraphs.isEmpty) {
      return Center(
        child: Text(
          '正文为空',
          key: const Key('audio_real_expanded_empty'),
          style: TextStyle(color: theme.muted, fontSize: 14),
        ),
      );
    }
    final highlight = _highlightAt(widget.position);
    _scheduleFollow(highlight);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : AudioRealExpandedTranscript.topFade +
                  AudioRealExpandedTranscript.bottomFade;
        final topStop = (AudioRealExpandedTranscript.topFade / height).clamp(
          0.0,
          0.5,
        );
        final bottomStop = (1 - AudioRealExpandedTranscript.bottomFade / height)
            .clamp(0.5, 1.0);
        return ShaderMask(
          key: const Key('audio_real_expanded'),
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [
              Color(0x00FFFFFF),
              Color(0xFFFFFFFF),
              Color(0xFFFFFFFF),
              Color(0x00FFFFFF),
            ],
            stops: [0, topStop, bottomStop, 1],
          ).createShader(bounds),
          child: SingleChildScrollView(
            key: const Key('audio_real_expanded_scroll'),
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(
              AudioRealExpandedTranscript.horizontalPadding,
              4,
              AudioRealExpandedTranscript.horizontalPadding,
              8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < _paragraphs.length; i++)
                  Padding(
                    key: _paragraphKeys[i],
                    padding: const EdgeInsets.only(
                      bottom: AudioRealExpandedTranscript.paragraphSpacing,
                    ),
                    child: _paragraphText(i, highlight, theme),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _paragraphText(
    int index,
    _WordHighlight? highlight,
    AudioPageTheme theme,
  ) {
    final paragraph = _paragraphs[index];
    final spans = <InlineSpan>[
      // 段首缩进 2 字：与阅读页一样用零高占位吃掉首行宽度。
      WidgetSpan(child: SizedBox(width: widget.fontSize * 2, height: 0)),
    ];
    final hit = highlight != null && highlight.index == index
        ? highlight
        : null;
    if (hit == null) {
      spans.add(TextSpan(text: paragraph.text));
    } else {
      if (hit.start > 0) {
        spans.add(TextSpan(text: paragraph.text.substring(0, hit.start)));
      }
      spans.add(
        TextSpan(
          text: paragraph.text.substring(hit.start, hit.end),
          style: TextStyle(
            backgroundColor: theme.accent.withValues(
              alpha: widget.dark
                  ? AudioRealExpandedTranscript.darkHighlightAlpha
                  : AudioRealExpandedTranscript.lightHighlightAlpha,
            ),
          ),
        ),
      );
      if (hit.end < paragraph.text.length) {
        spans.add(TextSpan(text: paragraph.text.substring(hit.end)));
      }
    }
    return Text.rich(
      TextSpan(
        style: TextStyle(
          color: theme.ink,
          fontSize: widget.fontSize,
          height: widget.lineHeight,
        ),
        children: spans,
      ),
      key: ValueKey(
        'audio_real_expanded_paragraph_${paragraph.paraIndex ?? index}',
      ),
      textAlign: TextAlign.justify,
    );
  }

  /// 当前播放位置落在哪个段落、句中的哪一段字符。
  ///
  /// 段落通过上游 `<p idx>` 匹配（[ChapterParagraph.paraIndex]）；时间点的
  /// 结束偏移是闭区间（阅读页同样 +1）。取不到对应段落/偏移就宁可不亮。
  _WordHighlight? _highlightAt(Duration position) {
    final point = widget.timeTrack.pointAt(position);
    if (point == null || !point.isBody) return null;
    var index = -1;
    for (var i = 0; i < _paragraphs.length; i++) {
      if (_paragraphs[i].paraIndex == point.startPara) {
        index = i;
        break;
      }
    }
    if (index < 0) return null;
    final paragraph = _paragraphs[index];
    final length = paragraph.text.length;
    final start = _startOffset(paragraph, point);
    if (start < 0 || start >= length) return null;
    var end = point.endPara == point.startPara ? point.endParaOff + 1 : length;
    if (end > length) end = length;
    if (end <= start) return null;
    return (index: index, start: start, end: end);
  }

  /// `positionV2` 落到具体 `<blk>` 时先把元素内的偏移换算成段内偏移。
  int _startOffset(ChapterParagraph paragraph, AudioSyncPoint point) {
    final spans = paragraph.blkSpans;
    if (spans.isEmpty || !point.hasElementCoordinate) {
      return point.startParaOff;
    }
    final elementIndex = point.startElementIndex!;
    final elementOffset = point.startElementOffset ?? 0;
    for (final span in spans) {
      if (span.elementIndex < elementIndex) continue;
      if (span.elementIndex == elementIndex) {
        final within = elementOffset < 0
            ? 0
            : (elementOffset > span.length ? span.length : elementOffset);
        return span.start + within;
      }
      break;
    }
    // 这个元素不在此段：退回段落级偏移，和阅读页的处理一致。
    return point.startParaOff;
  }

  /// 当前段落换了才滚一次；同一段里换词不打断阅读位置。
  void _scheduleFollow(_WordHighlight? highlight) {
    final index = highlight?.index ?? -1;
    if (index == _followedIndex || index < 0 || _followScheduled) return;
    _followedIndex = index;
    _followScheduled = true;
    final first = _firstFollow;
    _firstFollow = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || index >= _paragraphKeys.length) return;
      final paragraphContext = _paragraphKeys[index].currentContext;
      if (paragraphContext == null) return;
      Scrollable.ensureVisible(
        paragraphContext,
        alignment: 0.3,
        duration: first ? Duration.zero : const Duration(milliseconds: 250),
        curve: AudioRealExpandedTranscript.transitionCurve,
      );
    });
  }
}

/// 展开态底部「收起」胶囊（样稿 `.fold`：36dp 高、18dp 圆角、card 底）。
class AudioRealFoldButton extends StatelessWidget {
  static const height = 36.0;
  static const radius = 18.0;
  static const fontSize = 12.0;

  final VoidCallback? onTap;

  const AudioRealFoldButton({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return HomePressable(
      key: const Key('audio_real_fold'),
      semanticLabel: '收起',
      onTap: onTap ?? () {},
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: theme.card,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '收起',
              style: TextStyle(color: theme.ink, fontSize: fontSize),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_up, size: 12, color: theme.ink),
          ],
        ),
      ),
    );
  }
}
