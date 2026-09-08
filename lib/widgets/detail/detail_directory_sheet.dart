import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';
import 'detail_chapter_row.dart';

Future<Chapter?> showDetailDirectory(
  BuildContext context, {
  required List<Chapter> chapters,
  required String chapterUnit,
  int? currentIndex,
}) => showModalBottomSheet<Chapter>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: HomePalette.of(context).canvas,
  barrierColor: Colors.black.withValues(alpha: 0.42),
  clipBehavior: Clip.antiAlias,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
  ),
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: Duration(milliseconds: 320),
          reverseDuration: Duration(milliseconds: 240),
        ),
  builder: (context) => DetailDirectorySheet(
    chapters: chapters,
    chapterUnit: chapterUnit,
    currentIndex: currentIndex,
  ),
);

class DetailDirectorySheet extends StatefulWidget {
  final List<Chapter> chapters;
  final String chapterUnit;
  final int? currentIndex;

  const DetailDirectorySheet({
    super.key,
    required this.chapters,
    required this.chapterUnit,
    this.currentIndex,
  });

  @override
  State<DetailDirectorySheet> createState() => _DetailDirectorySheetState();
}

class _DetailDirectorySheetState extends State<DetailDirectorySheet> {
  final _search = TextEditingController();
  bool _reversed = false;
  late List<int> _visible;

  @override
  void initState() {
    super.initState();
    _filter();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _filter() {
    final query = _search.text.trim().toLowerCase();
    final ordinal = int.tryParse(query);
    _visible = [
      for (var index = 0; index < widget.chapters.length; index++)
        if (query.isEmpty ||
            (ordinal != null
                ? index + 1 == ordinal
                : widget.chapters[index].title.toLowerCase().contains(query) ||
                      widget.chapters[index].volumeName.toLowerCase().contains(
                        query,
                      )))
          index,
    ];
    if (_reversed) _visible = _visible.reversed.toList(growable: false);
  }

  void _clearSearch() {
    _search.clear();
    setState(_filter);
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.88,
        minChildSize: 0.45,
        maxChildSize: 0.96,
        builder: (context, controller) => CustomScrollView(
          key: const Key('detail_directory_scroll'),
          controller: controller,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            // The heading and search also scroll. Even with a large keyboard
            // and accessibility fonts they cannot overflow a fixed header.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                          color: palette.line,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '目录',
                            style: TextStyle(
                              color: palette.ink,
                              fontSize: 25,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          key: const Key('detail_directory_close'),
                          tooltip: '关闭目录',
                          onPressed: () => Navigator.pop(context),
                          style: IconButton.styleFrom(
                            backgroundColor: palette.soft,
                            foregroundColor: palette.ink,
                          ),
                          icon: const Icon(LucideIcons.x, size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '共 ${widget.chapters.length} ${widget.chapterUnit}',
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      key: const Key('detail_directory_search'),
                      controller: _search,
                      onChanged: (_) => setState(_filter),
                      onSubmitted: (_) => FocusScope.of(context).unfocus(),
                      textInputAction: TextInputAction.search,
                      style: TextStyle(color: palette.ink, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '搜索章节名称或序号',
                        hintStyle: TextStyle(color: palette.muted),
                        filled: true,
                        fillColor: palette.soft,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 16,
                        ),
                        prefixIcon: Icon(
                          LucideIcons.search,
                          size: 19,
                          color: palette.muted,
                        ),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清空搜索',
                                onPressed: _clearSearch,
                                icon: Icon(
                                  LucideIcons.x,
                                  size: 18,
                                  color: palette.muted,
                                ),
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(15),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(15),
                          borderSide: BorderSide(color: palette.accentText),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _search.text.trim().isEmpty
                                ? '全部章节'
                                : '找到 ${_visible.length} ${widget.chapterUnit}',
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          key: const Key('detail_directory_sort'),
                          onPressed: () => setState(() {
                            _reversed = !_reversed;
                            _filter();
                          }),
                          style: TextButton.styleFrom(
                            foregroundColor: palette.ink,
                            minimumSize: const Size(48, 48),
                          ),
                          icon: Icon(
                            _reversed
                                ? LucideIcons.arrow_up
                                : LucideIcons.arrow_down,
                            size: 16,
                          ),
                          label: Text(
                            _reversed ? '倒序' : '正序',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_visible.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 40,
                  ),
                  child: Column(
                    children: [
                      Icon(LucideIcons.search, color: palette.muted, size: 30),
                      const SizedBox(height: 14),
                      Text(
                        '没有找到匹配章节',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: palette.ink, fontSize: 16),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '换个名称，或输入章节序号',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: palette.muted, fontSize: 12),
                      ),
                      TextButton(
                        onPressed: _clearSearch,
                        style: TextButton.styleFrom(
                          foregroundColor: palette.accentText,
                        ),
                        child: const Text('清空搜索'),
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverList.builder(
                  itemCount: _visible.length,
                  itemBuilder: (context, position) {
                    final index = _visible[position];
                    final chapter = widget.chapters[index];
                    final showVolume =
                        chapter.volumeName.isNotEmpty &&
                        (position == 0 ||
                            chapter.volumeName !=
                                widget
                                    .chapters[_visible[position - 1]]
                                    .volumeName);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showVolume)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 20, 14, 10),
                            child: Text(
                              chapter.volumeName,
                              style: TextStyle(
                                color: palette.accentText,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                height: 1.5,
                              ),
                            ),
                          ),
                        DetailChapterRow(
                          key: ValueKey(
                            'detail_directory_chapter_${chapter.itemId}',
                          ),
                          chapter: chapter,
                          index: index,
                          current: index == widget.currentIndex,
                          onTap: () => Navigator.pop(context, chapter),
                        ),
                      ],
                    );
                  },
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 24 + MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
