import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/audio_page_theme.dart';
import '../home/home_design.dart';
import 'audio_cover_card.dart';

/// 真人讲书的书籍行（官方 `bjo.xml`，尺寸取合成样稿）。
///
/// 真人模式不再显示 0.72 屏宽的大封面：48×64 封面 + 本章集名/书名放在
/// 72dp 高的一行里，右侧 ⇋ 打开简介卡。智能朗读模式仍用大封面。
class AudioRealBookRow extends StatelessWidget {
  /// 书籍行总高（样稿）。
  static const double rowHeight = 72;

  /// 封面宽高（样稿；官方 `bjo.xml` 是 48×48，这里按样稿用竖版）。
  static const double coverWidth = 48;
  static const double coverHeight = 64;

  /// 封面 URL；空串时渲染占位图标。
  final String cover;

  /// 当前集标题，16sp w600。
  final String chapterTitle;

  /// 原著书名，14sp muted。真人模式下页面标题可能被主播名占用，所以调用方
  /// 传 [BookDetail.title]；为空时整行不渲染书名。
  final String bookTitle;

  /// 右侧 ⇋：打开简介卡。
  final VoidCallback? onSwap;

  const AudioRealBookRow({
    super.key,
    this.cover = '',
    required this.chapterTitle,
    this.bookTitle = '',
    this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return SizedBox(
      height: rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                key: const Key('audio_real_book_cover'),
                width: coverWidth,
                height: coverHeight,
                child: AudioCoverImage(url: cover),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chapterTitle,
                    key: const Key('audio_chapter_title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (bookTitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      bookTitle,
                      key: const Key('audio_real_book_title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: theme.muted, fontSize: 14),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            HomePressable(
              key: const Key('audio_real_swap'),
              semanticLabel: '书籍简介',
              onTap: onSwap ?? () {},
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.card,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  LucideIcons.arrow_right_left,
                  size: 16,
                  color: theme.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
