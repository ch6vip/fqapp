import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/audio_extra.dart';
import '../home/home_design.dart';

/// Listening page title with collapse and additional actions.
class AudioTopBar extends StatelessWidget {
  final VoidCallback onCollapse;
  final VoidCallback onMore;
  final VoidCallback? onInspire;

  const AudioTopBar({
    super.key,
    required this.onCollapse,
    required this.onMore,
    this.onInspire,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      height: 52,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.center,
            child: Semantics(
              header: true,
              child: Text(
                '听书',
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: '收起',
              onPressed: onCollapse,
              style: IconButton.styleFrom(foregroundColor: palette.ink),
              icon: const Icon(LucideIcons.chevron_down, size: 22),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onInspire != null)
                  HomePressable(
                    key: const Key('audio_inspire'),
                    semanticLabel: '听书激励',
                    onTap: onInspire!,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF0862B),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.sparkles,
                        size: 15,
                        color: Colors.white,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '更多',
                  onPressed: onMore,
                  style: IconButton.styleFrom(foregroundColor: palette.ink),
                  icon: const Icon(LucideIcons.ellipsis_vertical, size: 20),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Large cover card mirroring the official listening page: the chapter title
/// and the book title sit on the cover, the whole card opens the catalog, and
/// the top-right button switches the voice.
class AudioBookCard extends StatelessWidget {
  final String cover;
  final String bookTitle;
  final String chapterTitle;
  final VoidCallback? onSwitch;
  final VoidCallback? onOpenBook;

  const AudioBookCard({
    super.key,
    this.cover = '',
    required this.bookTitle,
    required this.chapterTitle,
    this.onSwitch,
    this.onOpenBook,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 293),
        child: AspectRatio(
          aspectRatio: 293 / 313,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _CoverImage(url: cover, palette: palette),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 150,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.72),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 58,
                  child: Text(
                    chapterTitle,
                    key: const Key('audio_chapter_title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ),
                // Keep the full-cover catalog target below the two buttons.
                // See .agents/notes/implemented/bug-fix/2026-09-16-cross-review-boundaries.md.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: onOpenBook,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 15,
                  height: 35,
                  child: HomePressable(
                    key: const Key('audio_book_bar'),
                    semanticLabel: '查看目录',
                    onTap: onOpenBook ?? () {},
                    borderRadius: BorderRadius.zero,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.3),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              bookTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            LucideIcons.chevron_right,
                            size: 13,
                            color: Colors.white70,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: HomePressable(
                    key: const Key('audio_cover_switch'),
                    semanticLabel: '切换音色',
                    onTap: onSwitch ?? () {},
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.28),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        LucideIcons.repeat,
                        size: 13,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CoverImage extends StatelessWidget {
  final String url;
  final HomePalette palette;

  const _CoverImage({required this.url, required this.palette});

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return Container(
        color: palette.soft,
        alignment: Alignment.center,
        child: Icon(LucideIcons.book_open, color: palette.muted, size: 36),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (context, _) => Container(color: palette.soft),
      errorWidget: (context, _, _) => Container(
        color: palette.soft,
        alignment: Alignment.center,
        child: Icon(LucideIcons.book_open, color: palette.muted, size: 36),
      ),
    );
  }
}

/// Two-line opening excerpt of the current chapter.
class AudioExcerpt extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;

  const AudioExcerpt({super.key, required this.text, this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      semanticLabel: '章节试读',
      onTap: onTap ?? () {},
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Text(
          text,
          key: const Key('audio_excerpt'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.ink.withValues(alpha: 0.82),
            fontSize: 15,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

/// `简介` block with genre tags, a clamped summary and an inline `更多`.
class AudioIntroSection extends StatefulWidget {
  final String text;
  final List<String> tags;

  const AudioIntroSection({
    super.key,
    required this.text,
    this.tags = const [],
  });

  @override
  State<AudioIntroSection> createState() => _AudioIntroSectionState();
}

class _AudioIntroSectionState extends State<AudioIntroSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (widget.text.isEmpty && widget.tags.isEmpty) {
      return const SizedBox.shrink();
    }
    final style = TextStyle(color: palette.muted, fontSize: 13, height: 1.8);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.line.withValues(alpha: 0.8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '简介',
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in widget.tags.take(5))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: palette.soft,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          tag,
                          style: TextStyle(
                            color: palette.muted,
                            fontSize: 11,
                            height: 1.3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (widget.text.isNotEmpty) ...[
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final measure = TextPainter(
                  text: TextSpan(text: widget.text, style: style),
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                  maxLines: 3,
                )..layout(maxWidth: constraints.maxWidth);
                final canExpand = measure.didExceedMaxLines;
                measure.dispose();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.text,
                      key: const Key('audio_intro_text'),
                      maxLines: _expanded ? null : 3,
                      overflow: _expanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: style,
                    ),
                    if (canExpand)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const Key('audio_intro_toggle'),
                          onPressed: () =>
                              setState(() => _expanded = !_expanded),
                          style: TextButton.styleFrom(
                            foregroundColor: palette.accentText,
                            minimumSize: const Size(48, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                          child: Text(
                            _expanded ? '收起' : '更多',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Companion works: the original novel and any adaptation.
class AudioRelatedRow extends StatelessWidget {
  final List<RelatedWork> works;
  final void Function(RelatedWork work) onTap;

  const AudioRelatedRow({super.key, required this.works, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (works.isEmpty) return const SizedBox.shrink();
    final textScaler = MediaQuery.textScalerOf(context);
    // A horizontal list forces a tight height on its cards, so derive the row
    // height from the scaled title/label instead of a fixed 76px.
    final rowHeight = math.max(
      76.0,
      textScaler.scale(12.5) * 1.35 * 2 +
          textScaler.scale(11) * 1.4 +
          5 +
          16 +
          4,
    );
    return SizedBox(
      height: rowHeight,
      child: ListView.separated(
        key: const Key('audio_related_row'),
        scrollDirection: Axis.horizontal,
        itemCount: works.length,
        separatorBuilder: (context, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final work = works[index];
          return HomePressable(
            key: ValueKey('audio_related_${work.kind}_${work.id}'),
            semanticLabel: '${work.label}：${work.title}',
            onTap: () => onTap(work),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 218,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: palette.line.withValues(alpha: 0.8)),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 44,
                      height: 58,
                      child: work.cover.isEmpty
                          ? ColoredBox(
                              color: palette.soft,
                              child: Icon(
                                work.kind == 'video'
                                    ? LucideIcons.clapperboard
                                    : LucideIcons.book,
                                size: 18,
                                color: palette.muted,
                              ),
                            )
                          : Image.network(
                              work.cover,
                              fit: BoxFit.cover,
                              errorBuilder: (context, _, _) => ColoredBox(
                                color: palette.soft,
                                child: Icon(
                                  LucideIcons.book,
                                  size: 18,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          work.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.ink,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          work.label,
                          style: TextStyle(color: palette.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 边听边读: the line being spoken plus the next one.
class AudioSubtitleView extends StatelessWidget {
  final SubtitleTrack track;
  final Duration position;

  const AudioSubtitleView({
    super.key,
    required this.track,
    required this.position,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (track.isEmpty) return const SizedBox.shrink();
    final (current, next) = track.windowAt(position);
    if (current == null && next == null) return const SizedBox.shrink();
    return Padding(
      key: const Key('audio_subtitles'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (current != null)
            Text(
              current.text,
              key: const Key('audio_subtitle_current'),
              style: TextStyle(
                color: palette.ink,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.6,
              ),
            ),
          if (next != null) ...[
            const SizedBox(height: 6),
            Text(
              next.text,
              key: const Key('audio_subtitle_next'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.muted.withValues(alpha: 0.75),
                fontSize: 14,
                height: 1.6,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One entry in the icon action row.
class AudioAction {
  const AudioAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String key;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
}

/// Icon + caption row (语速 / 加入书架 / 下载 / 章评 / 更多).
class AudioActionRow extends StatelessWidget {
  final List<AudioAction> actions;

  const AudioActionRow({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Row(
      children: [
        for (final action in actions)
          Expanded(
            child: HomePressable(
              key: ValueKey(action.key),
              semanticLabel: action.label,
              onTap: action.onTap ?? () {},
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      action.icon,
                      size: 21,
                      color: action.active ? palette.accentText : palette.ink,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      action.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: action.active
                            ? palette.accentText
                            : palette.muted,
                        fontSize: 11,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// `-15s  ──●──  08:40/09:01  +15s` row.
class AudioProgressRow extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final double? preview;
  final bool enabled;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final VoidCallback? onBack15;
  final VoidCallback? onForward15;

  const AudioProgressRow({
    super.key,
    required this.position,
    required this.duration,
    this.preview,
    this.enabled = true,
    this.onChanged,
    this.onChangeEnd,
    this.onBack15,
    this.onForward15,
  });

  static String time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 0x7fffffff);
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final maximum = duration.inMilliseconds.toDouble();
    final value = (preview ?? position.inMilliseconds.toDouble()).clamp(
      0.0,
      maximum > 0 ? maximum : 1.0,
    );
    final active = enabled && maximum > 0;
    return Column(
      children: [
        Row(
          children: [
            _SkipLabel(label: '-15s', tooltip: '后退15秒', onTap: onBack15),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  activeTrackColor: palette.accentText,
                  inactiveTrackColor: palette.line,
                  thumbColor: palette.accentText,
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                ),
                child: Slider(
                  key: const ValueKey('audio-seek'),
                  value: value,
                  max: maximum > 0 ? maximum : 1,
                  label: time(Duration(milliseconds: value.round())),
                  onChanged: active ? onChanged : null,
                  onChangeEnd: active ? onChangeEnd : null,
                ),
              ),
            ),
            _SkipLabel(label: '+15s', tooltip: '前进15秒', onTap: onForward15),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '${time(Duration(milliseconds: value.round()))}/${time(duration)}',
            key: const ValueKey('audio-position-label'),
            style: TextStyle(
              color: palette.muted,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _SkipLabel extends StatelessWidget {
  final String label;
  final String tooltip;
  final VoidCallback? onTap;

  const _SkipLabel({
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              color: onTap == null ? palette.line : palette.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Official two-card voice area: the left card lists the selectable voices
/// (智能朗读 / 真人讲书) and the right card is the 边听边读 entry.
class AudioToneSection extends StatelessWidget {
  final String title;
  final List<AudioTone> tones;
  final String selectedId;
  final String currentChapterTitle;
  final ValueChanged<AudioTone> onSelect;
  final VoidCallback onReadAlong;
  final VoidCallback? onShowVoices;

  const AudioToneSection({
    super.key,
    this.title = '智能朗读',
    required this.tones,
    required this.selectedId,
    required this.currentChapterTitle,
    required this.onSelect,
    required this.onReadAlong,
    this.onShowVoices,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final headerHeight = textScaler.scale(15) * 1.5 + 8;
    final chipHeight = math.max(
      64.0,
      textScaler.scale(12.5) * 1.5 + textScaler.scale(11) * 1.5 + 26,
    );
    // The left card stacks header + chips; the right card stacks header + a
    // two-line chapter title. Both must fit, at any system text scale.
    final cardHeight = math.max(
      116.0,
      math.max(
        16 + headerHeight + 4 + chipHeight,
        16 + headerHeight + 8 + textScaler.scale(13) * 1.5 * 2,
      ),
    );
    final ordered = [...tones];
    // The selected voice is shown first so the active choice is visible.
    ordered.sort((a, b) {
      if (a.id == selectedId) return -1;
      if (b.id == selectedId) return 1;
      return 0;
    });
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 237,
          child: Container(
            height: cardHeight,
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HomePressable(
                  key: const Key('audio-voice'),
                  semanticLabel: '选择音色',
                  onTap: onShowVoices ?? () {},
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.ink,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          LucideIcons.chevron_right,
                          size: 13,
                          color: palette.muted,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ordered.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '暂无可选音色',
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              for (var i = 0; i < ordered.length; i++) ...[
                                if (i > 0) const SizedBox(width: 6),
                                _AudioToneChip(
                                  tone: ordered[i],
                                  height: chipHeight,
                                  selected: ordered[i].id == selectedId,
                                  onTap: () => onSelect(ordered[i]),
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 133,
          child: Container(
            height: cardHeight,
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HomePressable(
                  key: const Key('audio_read_along'),
                  semanticLabel: '边听边读',
                  onTap: onReadAlong,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            '边听边读',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.ink,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          LucideIcons.chevron_right,
                          size: 13,
                          color: palette.muted,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      currentChapterTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 13,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AudioToneChip extends StatelessWidget {
  final AudioTone tone;
  final double height;
  final bool selected;
  final VoidCallback onTap;

  const _AudioToneChip({
    required this.tone,
    required this.height,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      key: ValueKey('audio_tone_${tone.id}'),
      semanticLabel: '选择音色 ${tone.title}',
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(minWidth: 96, maxWidth: 120),
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? palette.surface
              : palette.line.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? palette.accentText.withValues(alpha: 0.55)
                : Colors.transparent,
            width: selected ? 1.2 : 0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    tone.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? palette.accentText : palette.ink,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (tone.isMultiTone) ...[
                  const SizedBox(width: 4),
                  Icon(
                    LucideIcons.audio_lines,
                    size: 14,
                    color: selected ? palette.accentText : palette.muted,
                  ),
                ],
              ],
            ),
            if (tone.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                tone.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.muted, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
