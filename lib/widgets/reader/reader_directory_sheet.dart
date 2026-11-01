import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/reader_preferences.dart';
import 'reader_directory_fast_scroll.dart';
import 'reader_theme.dart';
import 'settings/reader_settings_widgets.dart';

/// Searchable chapter directory using the current reading palette.
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
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _searchFocus = FocusNode();
  late List<int> _indexes;
  double _itemExtent = 60;
  int _scrollRevision = 0;
  bool _reversed = false;
  String _query = '';
  // The directory can hold thousands of chapters; filtering on every keystroke
  // re-scans them all and rebuilds the sheet. Coalesce the input instead.
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _indexes = _visibleIndexes;
    _schedulePosition(current: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final extent = math.max(
      60.0,
      MediaQuery.textScalerOf(context).scale(15) * 1.35 * 2 + 16,
    );
    if (_itemExtent != extent) {
      final position = _scrollController.hasClients
          ? (_scrollController.offset / _itemExtent).floor()
          : null;
      _itemExtent = extent;
      _schedulePosition(current: position == null, position: position);
    }
  }

  @override
  void didUpdateWidget(ReaderDirectorySheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapters != widget.chapters ||
        oldWidget.currentIndex != widget.currentIndex) {
      _indexes = _visibleIndexes;
      _schedulePosition(current: true);
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      _applyQuery(value);
    });
  }

  void _applyQuery(String value) {
    _searchDebounce?.cancel();
    setState(() {
      _query = value.trim();
      _indexes = _visibleIndexes;
    });
    _schedulePosition(current: _query.isEmpty);
  }

  void _locateCurrent() {
    _searchFocus.unfocus();
    _searchController.clear();
    _applyQuery('');
  }

  void _schedulePosition({bool current = false, int? position}) {
    final revision = ++_scrollRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          revision != _scrollRevision ||
          !_scrollController.hasClients) {
        return;
      }
      final scroll = _scrollController.position;
      final index =
          position ?? (current ? _indexes.indexOf(widget.currentIndex) : 0);
      final offset =
          math.max(0, index) * _itemExtent +
          (current ? 8 : 0) -
          (current
              ? math.max(0, (scroll.viewportDimension - _itemExtent) / 2)
              : 0);
      _scrollController.jumpTo(offset.clamp(0.0, scroll.maxScrollExtent));
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
    setState(() {
      _reversed = !_reversed;
      _indexes = _visibleIndexes;
    });
    _schedulePosition(current: _query.isEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final currentValid =
        widget.currentIndex >= 0 &&
        widget.currentIndex < widget.chapters.length;
    final scaler = MediaQuery.textScalerOf(context);
    final searchHeight = math.max(48.0, scaler.scale(14) * 1.5 + 32) + 8;
    final statusHeight = math.max(48.0, scaler.scale(12) * 1.5 + 24);
    return ReaderSettingsSheetFrame(
      preset: preset,
      title: '目录 · ${widget.chapters.length} 章',
      closeTooltip: '关闭',
      scrollKey: const ValueKey('reader-directory-scroll'),
      maxHeightFactor: MediaQuery.viewInsetsOf(context).bottom > 0 ? 1 : .86,
      // 目录是长列表，用有界 body 让列表自己滚动：软键盘弹起时列表底边
      // 停在键盘上沿，而不是把整块内容继续往下铺到键盘下面。
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            if (constraints.maxHeight >= searchHeight + 24)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Row(
                  children: [
                    Expanded(child: _searchField(preset)),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: _reversed ? '切换为正序' : '切换为倒序',
                      child: TextButton(
                        onPressed: _toggleOrder,
                        style: TextButton.styleFrom(
                          foregroundColor: preset.textColor,
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _reversed
                                  ? LucideIcons.arrow_up
                                  : LucideIcons.arrow_down,
                              size: 18,
                            ),
                            Text(
                              _reversed ? '倒序' : '正序',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (constraints.maxHeight >= searchHeight + statusHeight + 60)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _query.isNotEmpty
                            ? '找到 ${_indexes.length} 章'
                            : currentValid
                            ? '当前第 ${widget.currentIndex + 1} 章'
                            : '章节列表',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: preset.mutedTextColor,
                        ),
                      ),
                    ),
                    Flexible(
                      child: TextButton.icon(
                        onPressed: currentValid ? _locateCurrent : null,
                        icon: const Icon(LucideIcons.locate_fixed, size: 16),
                        label: const Text(
                          '定位当前章',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: preset.accentColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Divider(height: 1, color: preset.borderColor),
            Expanded(
              child: _indexes.isEmpty
                  ? Center(
                      child: Text(
                        widget.chapters.isEmpty ? '暂无章节' : '没有匹配的章节',
                        style: TextStyle(color: preset.mutedTextColor),
                      ),
                    )
                  : ReaderDirectoryFastScroll(
                      controller: _scrollController,
                      chapters: widget.chapters,
                      indexes: _indexes,
                      preset: preset,
                      child: ListView.builder(
                        key: const ValueKey('reader-directory-scroll'),
                        controller: _scrollController,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemExtent: _itemExtent,
                        itemCount: _indexes.length,
                        itemBuilder: (context, position) =>
                            _row(context, _indexes[position], preset),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField(ReaderThemePreset preset) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _searchController,
        builder: (context, value, _) => TextField(
          controller: _searchController,
          focusNode: _searchFocus,
          textInputAction: TextInputAction.search,
          style: TextStyle(color: preset.textColor, fontSize: 14),
          onChanged: _onSearchChanged,
          onSubmitted: _applyQuery,
          decoration: InputDecoration(
            hintText: '搜索章节名或序号',
            hintStyle: TextStyle(color: preset.mutedTextColor),
            prefixIcon: Icon(
              LucideIcons.search,
              size: 20,
              color: preset.mutedTextColor,
            ),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空',
                    color: preset.mutedTextColor,
                    onPressed: () {
                      _searchController.clear();
                      _applyQuery('');
                    },
                    icon: const Icon(LucideIcons.x),
                  ),
            filled: true,
            fillColor: preset.fieldColor,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: preset.isEink
                  ? BorderSide(color: preset.borderColor)
                  : BorderSide.none,
            ),
          ),
        ),
      );

  Widget _row(BuildContext context, int index, ReaderThemePreset preset) {
    final chapter = widget.chapters[index];
    final current = index == widget.currentIndex;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        color: current && !preset.isEink
            ? preset.accentColor.withValues(alpha: 0.10)
            : Colors.transparent,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                width: 3,
                color: current ? preset.accentColor : Colors.transparent,
              ),
            ),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            minLeadingWidth: 28,
            horizontalTitleGap: 12,
            minTileHeight: _itemExtent - 4,
            titleAlignment: ListTileTitleAlignment.center,
            selected: current,
            selectedColor: preset.accentColor,
            textColor: preset.textColor,
            onTap: () => Navigator.pop(context, index),
            leading: SizedBox(
              width: math.max(
                28,
                MediaQuery.textScalerOf(context).scale(11) *
                    widget.chapters.length.toString().length *
                    .65,
              ),
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 11,
                  color: current ? preset.accentColor : preset.mutedTextColor,
                  fontWeight: current ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            title: Text(
              chapter.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                height: 1.35,
                fontWeight: current ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            trailing: widget.cachedIds.contains(chapter.itemId)
                ? Tooltip(
                    message: '已缓存',
                    child: Icon(
                      LucideIcons.circle_check,
                      size: 16,
                      color: preset.mutedTextColor,
                    ),
                  )
                : const SizedBox(width: 16),
          ),
        ),
      ),
    );
  }
}
