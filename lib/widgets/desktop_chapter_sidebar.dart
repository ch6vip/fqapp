import 'package:flutter/material.dart';
import '../models/media_item.dart';

class DesktopChapterSidebar extends StatefulWidget {
  const DesktopChapterSidebar({
    super.key,
    required this.chapters,
    required this.currentIndex,
    required this.onSelected,
    this.width = 248,
    this.chapterUnit = '章',
  });
  final double width;
  final String chapterUnit;
  final List<Chapter> chapters;
  final int currentIndex;
  final ValueChanged<int> onSelected;
  @override
  State<DesktopChapterSidebar> createState() => _DesktopChapterSidebarState();
}

class _DesktopChapterSidebarState extends State<DesktopChapterSidebar> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final indices = [
      for (var i = 0; i < widget.chapters.length; i++)
        if (_query.isEmpty || widget.chapters[i].title.contains(_query)) i,
    ];
    return SizedBox(
      width: widget.width,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '搜索目录',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value.trim()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('共 ${widget.chapters.length} ${widget.chapterUnit}'),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: indices.length,
                itemBuilder: (context, index) {
                  final i = indices[index];
                  return ListTile(
                    dense: true,
                    selected: i == widget.currentIndex,
                    selectedTileColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: .1),
                    title: Text(
                      widget.chapters[i].title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => widget.onSelected(i),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
