import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'comic_chrome_button.dart';

/// 漫画阅读器顶栏（AppBar actions）：条漫/翻页、刷新、书架、目录。
///
/// 与全局 chrome 同语言：Lucide 图标 + [ComicChromeButton]（内部走
/// HomePressable）。书架的图标与状态由调用方通过 [shelfAction] 注入，
/// 这样本组件不依赖 ShelfStore。
class ComicReaderToolbar extends StatelessWidget {
  const ComicReaderToolbar({
    super.key,
    required this.pagedMode,
    required this.enabled,
    required this.onTogglePagedMode,
    required this.onReload,
    required this.shelfAction,
    required this.onDirectory,
  });

  final bool pagedMode;
  final bool enabled;
  final VoidCallback onTogglePagedMode;
  final VoidCallback onReload;
  final Widget shelfAction;
  final VoidCallback onDirectory;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ComicChromeButton(
          tooltip: pagedMode ? '切换为条漫模式' : '切换为翻页模式',
          icon: pagedMode
              ? LucideIcons.gallery_vertical
              : LucideIcons.book_open,
          onPressed: enabled ? onTogglePagedMode : null,
        ),
        ComicChromeButton(
          tooltip: '刷新章节',
          icon: LucideIcons.refresh_cw,
          onPressed: enabled ? onReload : null,
        ),
        shelfAction,
        ComicChromeButton(
          tooltip: '目录',
          icon: LucideIcons.list,
          onPressed: onDirectory,
        ),
      ],
    ),
  );
}
