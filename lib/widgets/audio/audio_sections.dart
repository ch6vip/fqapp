import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/audio_extra.dart';
import '../../services/playback_format.dart';
import '../../services/poster_cache.dart';
import '../home/home_design.dart';

/// Listening page title with collapse and additional actions.
class AudioTopBar extends StatelessWidget {
  final VoidCallback onCollapse;
  final VoidCallback onMore;

  const AudioTopBar({
    super.key,
    required this.onCollapse,
    required this.onMore,
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
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: IconButton(
                tooltip: '更多',
                onPressed: onMore,
                style: IconButton.styleFrom(foregroundColor: palette.ink),
                icon: const Icon(LucideIcons.ellipsis_vertical, size: 20),
              ),
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
///
/// 真人讲书 uses the official 7.0.9.32 header instead of that plain cover:
/// `layout/bio.xml` is 72% of the screen wide, its gradient footer carries the
/// episode title, the book title and a `真人讲书・{主播}` row, and the card
/// flips over to the book intro card (`layout/bhi.xml`). All of it is opt-in —
/// a caller that passes neither [realAudio] nor [intro] keeps the original
/// single-sided card.
class AudioBookCard extends StatefulWidget {
  final String cover;
  final String bookTitle;
  final String chapterTitle;
  final VoidCallback? onSwitch;
  final VoidCallback? onOpenBook;

  /// Official 真人讲书 proportions: 72% of the screen, 12dip corners and a
  /// three-line gradient footer.
  final bool realAudio;

  /// Third footer line, e.g. `真人讲书・第 3 集`. Tapping it flips the card.
  final String? modeLabel;

  /// Flip side. Supplying it makes the card two-sided.
  final Widget? intro;

  const AudioBookCard({
    super.key,
    this.cover = '',
    required this.bookTitle,
    required this.chapterTitle,
    this.onSwitch,
    this.onOpenBook,
    this.realAudio = false,
    this.modeLabel,
    this.intro,
  });

  @override
  State<AudioBookCard> createState() => _AudioBookCardState();
}

class _AudioBookCardState extends State<AudioBookCard> {
  bool _showIntro = false;

  void _flip() => setState(() => _showIntro = !_showIntro);

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (!widget.realAudio) {
      // Original single-sided card; the width stays capped so narrow screens
      // still shrink it instead of overflowing.
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 293),
          child: _cover(palette),
        ),
      );
    }
    final width = (MediaQuery.sizeOf(context).width * 0.72).clamp(220.0, 420.0);
    final intro = widget.intro;
    if (intro == null) {
      return Center(
        child: SizedBox(width: width, child: _cover(palette)),
      );
    }
    // 翻转的两面必须同尺寸：背面是填充式卡片，没有固有高度，所以由外层
    // 给出封面的确定尺寸，避免 AnimatedSwitcher 在无界高度下排版失败。
    // 高度必须与 [_cover] 的画幅一致，否则翻面时两面尺寸不等会跳。
    final height = width * _coverAspect;
    return Center(
      child: SizedBox(
        width: width,
        height: height,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: KeyedSubtree(
            key: ValueKey<bool>(_showIntro),
            child: _showIntro
                ? _IntroSide(onBack: _flip, child: intro)
                : _cover(palette),
          ),
        ),
      ),
    );
  }

  /// 封面画幅：书封本身就是竖版，框也用竖版，`BoxFit.cover` 才不裁图。
  ///
  /// 所有调用方传的都是同一张竖版 `MediaItem.cover`（仓库里没有单独的方形
  /// 听书图），而详情页封面 3:4、信息流 5:7 用的也是这张图。原先的
  /// 293/313 近正方形框把竖版图上下裁掉约两成，对应 issue #85
  /// 「书籍封面显示不完整」。
  static const double _coverAspect = 3 / 4;

  Widget _cover(HomePalette palette) {
    final real = widget.realAudio;
    return AspectRatio(
      aspectRatio: _coverAspect,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(real ? 12 : 10),
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            fit: StackFit.expand,
            children: [
              _CoverImage(url: widget.cover, palette: palette),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: real ? math.max(96, constraints.maxWidth * 0.37) : 150,
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
              if (real)
                Positioned(left: 0, right: 0, bottom: 0, child: _realFooter())
              else ...[
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 58,
                  child: Text(
                    widget.chapterTitle,
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
                    onTap: widget.onOpenBook,
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
                    onTap: widget.onOpenBook ?? () {},
                    borderRadius: BorderRadius.zero,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.3),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.bookTitle,
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
              ],
              Positioned(
                top: 8,
                right: 8,
                child: HomePressable(
                  key: const Key('audio_cover_switch'),
                  semanticLabel: '切换音色',
                  onTap: widget.onSwitch ?? () {},
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
    );
  }

  /// `bio.xml` footer: 集标题 (18sp) / 书名 (18sp bold) / 副行 (14sp + chevron).
  /// The rows sit above the catalog tap target so each keeps its own action.
  Widget _realFooter() {
    final label = widget.modeLabel;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.chapterTitle,
            key: const Key('audio_chapter_title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 2),
          HomePressable(
            key: const Key('audio_book_bar'),
            semanticLabel: '查看目录',
            onTap: widget.onOpenBook ?? () {},
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                widget.bookTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
            ),
          ),
          if (label != null && label.isNotEmpty) ...[
            const SizedBox(height: 8),
            HomePressable(
              key: const Key('audio_mode_row'),
              semanticLabel: label,
              onTap: widget.intro == null ? () {} : _flip,
              borderRadius: BorderRadius.circular(6),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xB3FFFFFF),
                        fontSize: 14,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    LucideIcons.chevron_right,
                    size: 13,
                    color: Color(0xB3FFFFFF),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Back side of the cover card: the intro plus the way back.
class _IntroSide extends StatelessWidget {
  final VoidCallback onBack;
  final Widget child;

  const _IntroSide({required this.onBack, required this.child});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            top: 6,
            right: 6,
            child: HomePressable(
              key: const Key('audio_cover_back'),
              semanticLabel: '返回封面',
              onTap: onBack,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.soft,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  LucideIcons.chevron_down,
                  size: 13,
                  color: palette.muted,
                ),
              ),
            ),
          ),
        ],
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
      cacheManager: PosterCache.instance,
      imageUrl: url,
      fit: BoxFit.cover,
      // The big cover renders at ~293 logical px; decode at 2× instead of the
      // original resolution (typically 600-1000px wide).
      memCacheWidth: 640,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
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
                              // 44x58 logical thumbnail; decode at 2×.
                              cacheWidth: 96,
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

/// `layout/bjg.xml`: 24dp 后退/前进图标夹一条 2dip 细轨。
///
/// 官方默认不在这行放时间文字——带左右时间的那套（`fud`）在 7.0.9.32 里是
/// `visibility="gone"` 的备用变体，时长信息由页头与拖动标签承担。
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

  static String time(Duration value) => formatPlaybackTime(value);

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final maximum = duration.inMilliseconds.toDouble();
    final value = (preview ?? position.inMilliseconds.toDouble()).clamp(
      0.0,
      maximum > 0 ? maximum : 1.0,
    );
    final active = enabled && maximum > 0;
    return Row(
      children: [
        _SkipIcon(
          icon: LucideIcons.rotate_ccw,
          tooltip: '后退15秒',
          onTap: onBack15,
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              activeTrackColor: palette.accentText,
              inactiveTrackColor: palette.line,
              thumbColor: palette.accentText,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4.5),
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
        _SkipIcon(
          icon: LucideIcons.rotate_cw,
          tooltip: '前进15秒',
          onTap: onForward15,
        ),
      ],
    );
  }
}

class _SkipIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _SkipIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      iconSize: 24,
      style: IconButton.styleFrom(
        foregroundColor: palette.muted,
        disabledForegroundColor: palette.line,
      ),
      icon: Icon(icon),
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

/// Official 真人讲书 keeps the spoken line on the page itself (`bio.xml` fs6:
/// `AudioPlaySubtitleView`, 52dip, two lines with a fading edge). The sheet
/// behind [onTap] stays the way to see the whole track.
class AudioInlineSubtitle extends StatelessWidget {
  final SubtitleTrack track;
  final Duration position;
  final VoidCallback onTap;

  const AudioInlineSubtitle({
    super.key,
    required this.track,
    required this.position,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (track.isEmpty) return const SizedBox.shrink();
    final palette = HomePalette.of(context);
    final (current, next) = track.windowAt(position);
    final line = current ?? next;
    final following = current == null ? null : next;
    if (line == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: HomePressable(
        key: const Key('audio_read_along'),
        semanticLabel: '边听边读',
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: 52,
          width: double.infinity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                line.text,
                key: const Key('audio-inline-subtitle-current'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 14.5,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (following != null) ...[
                const SizedBox(height: 2),
                Text(
                  following.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// `layout/hy.xml`: the `AI朗读 │ 真人讲书` header switch. Only meaningful when
/// the book really offers both families, so the page decides when to show it.
class AudioModeSwitch extends StatelessWidget {
  final bool realSelected;
  final VoidCallback onSelectTts;
  final VoidCallback onSelectNarrator;

  const AudioModeSwitch({
    super.key,
    required this.realSelected,
    required this.onSelectTts,
    required this.onSelectNarrator,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tab(
              key: const Key('audio_mode_tts'),
              label: 'AI朗读',
              selected: !realSelected,
              palette: palette,
              onTap: onSelectTts,
            ),
            Container(
              width: 0.5,
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 9),
              color: palette.line,
            ),
            _tab(
              key: const Key('audio_mode_narrator'),
              label: '真人讲书',
              selected: realSelected,
              palette: palette,
              onTap: onSelectNarrator,
            ),
          ],
        ),
      ),
    );
  }

  Widget _tab({
    required Key key,
    required String label,
    required bool selected,
    required HomePalette palette,
    required VoidCallback onTap,
  }) {
    return HomePressable(
      key: key,
      semanticLabel: label,
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? palette.accentText : palette.muted,
            fontSize: 16,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Compact replacement for the voice card in 真人讲书 mode.
///
/// The official page hides the 智能朗读 tone card for a recording
/// (`bj1.xml` `a5h` is `gone`); narrators are switched elsewhere. One row is
/// enough here and still opens the voice sheet that carries every version.
class AudioRealVersionRow extends StatelessWidget {
  /// Upstream narrator label, already in `主播：…` form.
  final String narrator;
  final VoidCallback? onTap;

  const AudioRealVersionRow({super.key, this.narrator = '', this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: HomePressable(
        key: const Key('audio-voice'),
        semanticLabel: '选择音色',
        onTap: onTap ?? () {},
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: palette.soft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Text(
                '真人讲书',
                style: TextStyle(
                  color: palette.accentText,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  narrator.isEmpty ? '暂无可选音色' : narrator,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: narrator.isEmpty ? palette.muted : palette.ink,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text('换版本', style: TextStyle(color: palette.muted, fontSize: 12)),
              const SizedBox(width: 2),
              Icon(LucideIcons.chevron_right, size: 14, color: palette.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Back side of the 真人讲书 cover card: the official `layout/bhi.xml`
/// (`layout_audio_book_detail_info_0`) — thumbnail, title, author, meta row,
/// expandable 简介 and one related work.
class AudioIntroCard extends StatefulWidget {
  final String cover;
  final String title;
  final String author;
  final List<String> meta;
  final String summary;
  final RelatedWork? related;
  final void Function(RelatedWork work)? onOpenRelated;

  const AudioIntroCard({
    super.key,
    this.cover = '',
    required this.title,
    this.author = '',
    this.meta = const [],
    this.summary = '',
    this.related,
    this.onOpenRelated,
  });

  @override
  State<AudioIntroCard> createState() => _AudioIntroCardState();
}

class _AudioIntroCardState extends State<AudioIntroCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final related = widget.related;
    final summary = widget.summary.isEmpty ? '暂无简介' : widget.summary;
    return ColoredBox(
      color: palette.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 36,
                    height: 54,
                    child: _CoverImage(url: widget.cover, palette: palette),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        key: const Key('audio_intro_title'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                      ),
                      if (widget.author.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          widget.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: palette.muted, fontSize: 12),
                        ),
                      ],
                      if (widget.meta.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          widget.meta.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: palette.muted, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Divider(height: 1, color: palette.line.withValues(alpha: 0.7)),
            const SizedBox(height: 10),
            Text(
              '简介',
              style: TextStyle(
                color: palette.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              summary,
              key: const Key('audio_intro_summary'),
              maxLines: _expanded ? 40 : 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.ink, fontSize: 13, height: 1.6),
            ),
            if (summary.length > 60)
              GestureDetector(
                key: const Key('audio_intro_more'),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _expanded ? '收起' : '展开',
                    style: TextStyle(
                      color: palette.accentText,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            if (related != null) ...[
              const SizedBox(height: 10),
              HomePressable(
                key: const Key('audio_intro_related'),
                semanticLabel: '${related.label}：${related.title}',
                onTap: () => widget.onOpenRelated?.call(related),
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: 28,
                        height: 40,
                        child: related.cover.isEmpty
                            ? ColoredBox(
                                color: palette.soft,
                                child: Icon(
                                  related.kind == 'video'
                                      ? LucideIcons.clapperboard
                                      : LucideIcons.book,
                                  size: 14,
                                  color: palette.muted,
                                ),
                              )
                            : Image.network(
                                related.cover,
                                fit: BoxFit.cover,
                                cacheWidth: 64,
                                errorBuilder: (context, _, _) => ColoredBox(
                                  color: palette.soft,
                                  child: Icon(
                                    LucideIcons.book,
                                    size: 14,
                                    color: palette.muted,
                                  ),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            related.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.ink,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            related.label,
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      LucideIcons.chevron_right,
                      size: 14,
                      color: palette.muted,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
