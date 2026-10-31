import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/reader_preferences.dart';
import 'reader_theme.dart';
import 'settings/reader_settings_widgets.dart';

/// The reader's chapter directory sheet. Extracted from `reader_page.dart` to
/// keep that file under its line budget; behavior is unchanged.
class ReaderDirectorySheet extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentIndex;
  final Set<String> cachedIds;

  /// 阅读背景 preset：面板骨架、文字和控件配色都跟着它走。
  final ReaderThemePreset preset;

  const ReaderDirectorySheet({
    super.key,
    required this.chapters,
    required this.currentIndex,
    required this.cachedIds,
    this.preset = ReaderThemePreset.light,
  });

  @override
  State<ReaderDirectorySheet> createState() => _ReaderDirectorySheetState();
}

class _ReaderDirectorySheetState extends State<ReaderDirectorySheet> {
  static const _itemExtent = 58.0;

  final TextEditingController _searchController = TextEditingController();
  late final ScrollController _scrollController;
  bool _reversed = false;
  String _query = '';
  // The directory can hold thousands of chapters; filtering on every keystroke
  // re-scans them all and rebuilds the sheet. Coalesce the input instead.
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    final initialOffset = (widget.currentIndex * _itemExtent - 120).clamp(
      0.0,
      double.infinity,
    );
    _scrollController = ScrollController(initialScrollOffset: initialOffset);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() => _query = value);
    });
  }

  List<int> get _visibleIndexes {
    Iterable<int> indexes = Iterable<int>.generate(widget.chapters.length);
    if (_reversed) indexes = indexes.toList(growable: false).reversed;
    final query = _query.trim().toLowerCase();
    if (query.isNotEmpty) {
      indexes = indexes.where((index) {
        final chapter = widget.chapters[index];
        return chapter.title.toLowerCase().contains(query) ||
            '${index + 1}'.contains(query);
      });
    }
    return indexes.toList(growable: false);
  }

  void _toggleOrder() {
    setState(() => _reversed = !_reversed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients || _query.isNotEmpty) return;
      final displayIndex = _reversed
          ? widget.chapters.length - 1 - widget.currentIndex
          : widget.currentIndex;
      final target = (displayIndex * _itemExtent - 120).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final indexes = _visibleIndexes;
    return ReaderSettingsSheetFrame(
      preset: preset,
      title: '目录 · ${widget.chapters.length} 章',
      closeTooltip: '关闭',
      scrollKey: const ValueKey('reader-directory-scroll'),
      // 目录是长列表，用有界 body 让列表自己滚动：软键盘弹起时列表底边
      // 停在键盘上沿，而不是把整块内容继续往下铺到键盘下面。
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(child: _searchField(preset)),
                IconButton(
                  tooltip: _reversed ? '切换为正序' : '切换为倒序',
                  onPressed: _toggleOrder,
                  color: preset.textColor,
                  icon: Icon(
                    _reversed ? LucideIcons.arrow_up : LucideIcons.arrow_down,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: indexes.isEmpty
                ? Center(
                    child: Text(
                      '没有匹配的章节',
                      style: TextStyle(color: preset.mutedTextColor),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemExtent: _itemExtent,
                    itemCount: indexes.length,
                    itemBuilder: (context, position) =>
                        _row(context, indexes[position], preset),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _searchField(ReaderThemePreset preset) => TextField(
    controller: _searchController,
    textInputAction: TextInputAction.search,
    style: TextStyle(color: preset.textColor),
    onChanged: _onSearchChanged,
    decoration: InputDecoration(
      hintText: '搜索章节名或序号',
      hintStyle: TextStyle(color: preset.mutedTextColor),
      prefixIcon: Icon(LucideIcons.search, color: preset.mutedTextColor),
      suffixIcon: _query.isEmpty
          ? null
          : IconButton(
              tooltip: '清空',
              color: preset.mutedTextColor,
              onPressed: () {
                _searchDebounce?.cancel();
                _searchController.clear();
                setState(() => _query = '');
              },
              icon: const Icon(LucideIcons.x),
            ),
      filled: true,
      fillColor: preset.fieldColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
  );

  Widget _row(BuildContext context, int index, ReaderThemePreset preset) {
    final chapter = widget.chapters[index];
    final current = index == widget.currentIndex;
    return Material(
      color: current
          ? preset.accentColor.withValues(alpha: 0.14)
          : Colors.transparent,
      child: ListTile(
        dense: true,
        selected: current,
        onTap: () => Navigator.pop(context, index),
        leading: SizedBox(
          width: 42,
          child: Text(
            '${index + 1}',
            textAlign: TextAlign.end,
            style: TextStyle(
              color: current ? preset.accentColor : preset.mutedTextColor,
              fontWeight: current ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
        title: Text(
          chapter.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.cachedIds.contains(chapter.itemId))
              Tooltip(
                message: '已缓存',
                child: Icon(
                  LucideIcons.circle_check,
                  size: 18,
                  color: preset.mutedTextColor,
                ),
              ),
            if (current)
              Icon(LucideIcons.locate_fixed, color: preset.accentColor),
          ],
        ),
      ),
    );
  }
}
