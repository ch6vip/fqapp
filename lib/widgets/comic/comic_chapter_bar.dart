import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';
import 'comic_chrome_button.dart';

/// 漫画阅读器底栏：上一章 / 章节与页码 / 下一章。
///
/// 配色跟随 [HomePalette]（墨水屏白底黑字黑线），按钮走
/// [ComicChromeButton]；两条文案保持原来的 `第 X / Y 章` 与
/// `第 X / Y 页` 结构。
class ComicChapterBar extends StatelessWidget {
  const ComicChapterBar({
    super.key,
    required this.chapterIndex,
    required this.chapterCount,
    required this.visiblePage,
    required this.pageCount,
    required this.onPrevious,
    required this.onNext,
  });

  final int chapterIndex;
  final int chapterCount;
  final int visiblePage;
  final int pageCount;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  String get _pageLabel =>
      pageCount == 0 ? '漫画阅读' : '第 ${visiblePage + 1} / $pageCount 页';

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Material(
      key: const Key('comic_chapter_bar'),
      color: palette.canvas,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.line, width: 0.6)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              children: [
                ComicChromeButton(
                  tooltip: '上一章',
                  icon: LucideIcons.skip_back,
                  onPressed: onPrevious,
                ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '第 ${chapterIndex + 1} / $chapterCount 章',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          color: palette.muted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _pageLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: palette.ink,
                        ),
                      ),
                    ],
                  ),
                ),
                ComicChromeButton(
                  tooltip: '下一章',
                  icon: LucideIcons.skip_forward,
                  onPressed: onNext,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
