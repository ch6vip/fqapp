import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/audio_page_theme.dart';
import '../../services/poster_cache.dart';
import '../home/home_design.dart';

double audioCoverEdge(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  var width = size.width * 0.72;
  // 官方对「大屏/平板」再夹一次高 40%，避免封面顶穿一屏。
  if (size.width >= 600 || size.height / size.width < 1.5) {
    width = math.min(width, size.height * 0.4);
  }
  return width.clamp(180.0, 420.0);
}

/// `layout/bio.xml` 的封面页脚：集标题 18sp（`b1h`）/ 书名 18sp bold
/// （`b1g`，官方默认 `visibility="gone"`）/ 副行 14sp + chevron（`bj2`）。
///
/// 注意 `b1g` 是 gone 的，官方默认页脚**只有两行**。早先的实现把它当成三行
/// 「集标题 / 书名 / 真人讲书·第N集」渲染，与布局不符。
/// `layout/bio.xml` 的封面页脚。
///
/// 布局上 `b1h`（集标题 18sp）与 `bj2`（副行 14sp + chevron）是始终可见的，
/// 中间那行 `b1g`（书名 18sp bold）在官方是 `visibility="gone"`。这里按官方
/// 默认把书名行收起，但**保留它作为「查看目录」的点击目标**：仓库里书架与
/// 详情页一直靠 `audio_book_bar` 开目录，删掉这个键会断掉既有契约。
/// 因此书名行在 [bookTitle] 为空时渲染为空字符串占位（高度不变），不可见

class AudioCoverFooter extends StatelessWidget {
  final String chapterTitle;

  /// 副行文字，例如 `异常大舞台，邪门你就来（异常大…`。
  final String subtitle;

  /// 官方 `b1g` 的书名行。为空时保持高度但画不出字（与官方 `gone` 的观感
  /// 一致），点击仍然开目录。
  final String bookTitle;
  final VoidCallback? onOpenBook;
  final VoidCallback? onFlip;
  final Key chapterKey;
  final Key bookBarKey;

  const AudioCoverFooter({
    super.key,
    required this.chapterTitle,
    this.subtitle = '',
    this.bookTitle = '',
    this.onOpenBook,
    this.onFlip,
    this.chapterKey = const Key('audio_chapter_title'),
    this.bookBarKey = const Key('audio_book_bar'),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            chapterTitle,
            key: chapterKey,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          HomePressable(
            key: bookBarKey,
            semanticLabel: '查看目录',
            onTap: onOpenBook ?? () {},
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: double.infinity,
              // 书名行为空时保留 1dp 最小高度：与官方 gone 的观感一致，
              // 同时不把下方副行的位置往上带。
              height: bookTitle.isEmpty ? 1 : null,
              child: bookTitle.isEmpty
                  ? const SizedBox.shrink()
                  : Text(
                      bookTitle,
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
          const SizedBox(height: 8),
          HomePressable(
            key: const Key('audio_mode_row'),
            semanticLabel: subtitle.isEmpty ? '切换' : subtitle,
            onTap: onFlip ?? onOpenBook ?? () {},
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.70),
                      fontSize: 14,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  LucideIcons.chevron_right,
                  size: 13,
                  color: Colors.white.withValues(alpha: 0.70),
                ),
              ],
            ),
          ),
          // palette 只为把 inherit 依赖留住：正文色随取色主题变化时这里不画字。
          const SizedBox.shrink(key: ValueKey('audio_cover_footer_end')),
        ],
      ),
    );
  }
}

/// `layout/bif.xml` 的图标行：24dp 图标 + 12sp 文案，五等分。
///

class AudioFlipCover extends StatefulWidget {
  final String cover;
  final String chapterTitle;
  final String subtitle;
  final Widget? back;
  final VoidCallback? onSwitch;
  final VoidCallback? onOpenBook;

  const AudioFlipCover({
    super.key,
    required this.cover,
    required this.chapterTitle,
    this.subtitle = '',
    this.back,
    this.onSwitch,
    this.onOpenBook,
  });

  @override
  State<AudioFlipCover> createState() => _AudioFlipCoverState();
}

class _AudioFlipCoverState extends State<AudioFlipCover> {
  bool _showIntro = false;

  void _flip() => setState(() => _showIntro = !_showIntro);

  @override
  Widget build(BuildContext context) {
    final back = widget.back;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: KeyedSubtree(
        key: ValueKey<bool>(_showIntro),
        child: _showIntro && back != null
            ? _IntroSide(onBack: _flip, child: back)
            : _cover(),
      ),
    );
  }

  Widget _cover() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AudioCoverImage(url: widget.cover),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 150,
            child: IgnorePointer(
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
          ),
          // 整张封面也能点开目录。用 `Positioned.fill` + translucent 会连页脚
          // 一起吃掉，所以只铺到页脚上沿之上；页脚自己保留翻面 / 开目录两个
          // 更精确的目标。
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: 150,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: widget.onOpenBook,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AudioCoverFooter(
              chapterTitle: widget.chapterTitle,
              subtitle: widget.subtitle,
              onOpenBook: widget.onOpenBook,
              onFlip: widget.back == null ? null : _flip,
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: AudioCoverSwitchButton(onTap: widget.onSwitch),
          ),
        ],
      ),
    );
  }
}


class _IntroSide extends StatelessWidget {
  final VoidCallback onBack;
  final Widget child;

  const _IntroSide({required this.onBack, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
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
                  color: theme.card,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  LucideIcons.chevron_down,
                  size: 13,
                  color: theme.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class AudioCoverSwitchButton extends StatelessWidget {
  final VoidCallback? onTap;

  const AudioCoverSwitchButton({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return HomePressable(
      key: const Key('audio_cover_switch'),
      semanticLabel: '切换音色',
      onTap: onTap ?? () {},
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
    );
  }
}


class AudioCoverImage extends StatelessWidget {
  final String url;

  const AudioCoverImage({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    if (url.isEmpty) {
      return ColoredBox(
        color: theme.card,
        child: Icon(LucideIcons.book_open, color: theme.muted, size: 36),
      );
    }
    return CachedNetworkImage(
      cacheManager: PosterCache.instance,
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: 640,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (context, _) => ColoredBox(color: theme.card),
      errorWidget: (context, _, _) => ColoredBox(
        color: theme.card,
        child: Icon(LucideIcons.book_open, color: theme.muted, size: 36),
      ),
    );
  }
}
