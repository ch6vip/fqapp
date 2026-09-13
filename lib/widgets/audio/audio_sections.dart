import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/audio_extra.dart';
import '../home/home_design.dart';

/// Collapsible top bar: `智能朗读 | 真人讲书` mode switch on the left, a live
/// dot and the overflow menu on the right.
class AudioTopBar extends StatelessWidget {
  final String modeLabel;
  final bool live;
  final VoidCallback onCollapse;
  final VoidCallback onMore;
  final VoidCallback? onSwitchMode;

  const AudioTopBar({
    super.key,
    required this.modeLabel,
    required this.onCollapse,
    required this.onMore,
    this.live = true,
    this.onSwitchMode,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            tooltip: '收起',
            onPressed: onCollapse,
            style: IconButton.styleFrom(foregroundColor: palette.ink),
            icon: const Icon(LucideIcons.chevron_down, size: 22),
          ),
          Expanded(
            child: HomePressable(
              key: const Key('audio_mode_switch'),
              semanticLabel: '切换朗读模式，当前 $modeLabel',
              onTap: onSwitchMode ?? () {},
              borderRadius: BorderRadius.circular(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    modeLabel,
                    style: TextStyle(
                      color: palette.ink,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (onSwitchMode != null) ...[
                    const SizedBox(width: 5),
                    Icon(
                      LucideIcons.chevron_down,
                      size: 13,
                      color: palette.muted,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (live)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFFF0862B),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          IconButton(
            tooltip: '更多',
            onPressed: onMore,
            style: IconButton.styleFrom(foregroundColor: palette.ink),
            icon: const Icon(LucideIcons.ellipsis_vertical, size: 20),
          ),
        ],
      ),
    );
  }
}

/// Title card with the catalog shortcut, mirroring the official listening page.
class AudioBookCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onCatalog;

  const AudioBookCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onCatalog,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.line.withValues(alpha: 0.8)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  key: const Key('audio_book_title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            key: const Key('audio_catalog_inline'),
            tooltip: '章节目录',
            onPressed: onCatalog,
            style: IconButton.styleFrom(foregroundColor: palette.ink),
            icon: const Icon(LucideIcons.list, size: 19),
          ),
        ],
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

/// 智能朗读 voice picker plus the 边听边读 companion card.
class AudioToneSection extends StatelessWidget {
  final List<AudioTone> tones;
  final String selectedId;
  final String currentChapterTitle;
  final ValueChanged<AudioTone> onSelect;
  final VoidCallback onReadAlong;

  const AudioToneSection({
    super.key,
    required this.tones,
    required this.selectedId,
    required this.currentChapterTitle,
    required this.onSelect,
    required this.onReadAlong,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    // Tone and read-along cards live in a fixed-height horizontal list; derive
    // that height from the scaled text instead of a hard-coded 72px.
    final cardHeight = math.max(
      72.0,
      math.max(
        textScaler.scale(12) * 1.6 + textScaler.scale(11) * 1.6 + 5 + 16,
        textScaler.scale(12) * 1.35 * 2 + 20 + 4,
      ),
    );
    final ordered = [...tones];
    // The selected voice is shown first so the active choice is visible.
    ordered.sort((a, b) {
      if (a.id == selectedId) return -1;
      if (b.id == selectedId) return 1;
      return 0;
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '智能朗读',
              style: TextStyle(
                color: palette.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
            Icon(LucideIcons.chevron_right, size: 15, color: palette.muted),
            const Spacer(),
            Text(
              '边听边读',
              style: TextStyle(
                color: palette.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
            Icon(LucideIcons.chevron_right, size: 15, color: palette.muted),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (ordered.isNotEmpty)
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: cardHeight,
                  child: ListView.separated(
                    key: const Key('audio_tone_list'),
                    scrollDirection: Axis.horizontal,
                    itemCount: ordered.length,
                    separatorBuilder: (context, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final tone = ordered[index];
                      final selected = tone.id == selectedId;
                      return HomePressable(
                        key: ValueKey('audio_tone_${tone.id}'),
                        semanticLabel: '选择音色 ${tone.title}',
                        onTap: () => onSelect(tone),
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 116,
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                          decoration: BoxDecoration(
                            color: palette.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: selected
                                  ? palette.accentText.withValues(alpha: 0.6)
                                  : palette.line.withValues(alpha: 0.8),
                              width: selected ? 1.2 : 0.8,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      tone.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: selected
                                            ? palette.accentText
                                            : palette.ink,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (tone.badge.isNotEmpty)
                                    Container(
                                      margin: const EdgeInsets.only(left: 4),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: HomePalette.accent.withValues(
                                          alpha: 0.14,
                                        ),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: Text(
                                        tone.badge,
                                        style: const TextStyle(
                                          color: HomePalette.accent,
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Text(
                                tone.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.muted,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            if (ordered.isNotEmpty) const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: HomePressable(
                key: const Key('audio_read_along'),
                semanticLabel: '边听边读',
                onTap: onReadAlong,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  height: cardHeight,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: palette.line.withValues(alpha: 0.8),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        currentChapterTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.ink,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
