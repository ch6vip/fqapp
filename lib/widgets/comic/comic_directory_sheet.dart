import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';
import '../home/home_sheet.dart';

/// 漫画目录弹层：走统一的 [showHomeSheet] / [HomeSheetFrame]。
///
/// 返回被点选的章节下标（关闭返回 null）。行是项目自己的设计（不是官方
/// 目录）：soft 底选中、勾选图标、左侧章节序号；墨水屏下选中行额外加一圈
/// 黑描边，避免 `soft` 变白后选中态消失。
Future<int?> showComicDirectorySheet({
  required BuildContext context,
  required List<Chapter> chapters,
  required int currentIndex,
}) => showHomeSheet<int>(
  context: context,
  title: '目录 · 共 ${chapters.length} 章',
  contentPadding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
  children: [
    SizedBox(
      height: _listHeight(context, chapters.length),
      child: _ComicDirectoryList(
        chapters: chapters,
        currentIndex: currentIndex,
      ),
    ),
  ],
);

double _listHeight(BuildContext context, int count) => math.min(
  count * _ComicDirectoryList.itemExtent,
  MediaQuery.sizeOf(context).height * 0.55,
);

class _ComicDirectoryList extends StatefulWidget {
  static const double itemExtent = 56.0;

  final List<Chapter> chapters;
  final int currentIndex;

  const _ComicDirectoryList({
    required this.chapters,
    required this.currentIndex,
  });

  @override
  State<_ComicDirectoryList> createState() => _ComicDirectoryListState();
}

class _ComicDirectoryListState extends State<_ComicDirectoryList> {
  late final _controller = ScrollController(
    initialScrollOffset: widget.currentIndex * _ComicDirectoryList.itemExtent,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: _controller,
    itemExtent: _ComicDirectoryList.itemExtent,
    itemCount: widget.chapters.length,
    itemBuilder: (context, index) => _ChapterRow(
      chapter: widget.chapters[index],
      index: index,
      selected: index == widget.currentIndex,
    ),
  );
}

class _ChapterRow extends StatelessWidget {
  final Chapter chapter;
  final int index;
  final bool selected;

  const _ChapterRow({
    required this.chapter,
    required this.index,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: HomePressable(
        onTap: () => Navigator.pop(context, index),
        semanticLabel: selected ? '${chapter.title}，当前章节' : chapter.title,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          key: selected ? const Key('comic-directory-current') : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? palette.soft : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            // 墨水屏 soft 也是白，光靠底色看不出选中；补一圈黑描边。
            border: selected && palette.eink
                ? Border.all(color: palette.line, width: 1)
                : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  '${index + 1}',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: selected ? palette.accentText : palette.muted,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: palette.ink,
                  ),
                ),
              ),
              if (selected)
                Icon(LucideIcons.check, size: 18, color: palette.accentText),
            ],
          ),
        ),
      ),
    );
  }
}
