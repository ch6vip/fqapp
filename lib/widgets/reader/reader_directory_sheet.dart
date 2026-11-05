// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/reader_catalogue.dart -> ReaderCatalogue (header, search toggle, order
//                                   control, current/cached row labels)
//
// fqapp keeps its own sheet route, debounced filtering, reversed projection,
// itemExtent and the fast-scroll handle. The upstream volume grouping is not
// carried because fqapp's `Chapter` list is already a flat directory.
//
// Mechanical substitutions:
// - `app_ui.dart` AppText/GlassIconButton/GlassTextButton/JellyTapSurface ->
//   shared `lib/widgets/wenku` exports.
// - `AppSearchField` -> the already-ported shared widget.
// - `NovelMotion` -> `WenkuMotion`.
// - The upstream row layout (number column, title, 正在阅读 / 已缓存 labels)
//   is kept; fqapp renders it with ListTile so the existing selected-row
//   accessibility and tests continue to address the same semantics.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../services/reader_preferences.dart';
import '../wenku/wenku_ui.dart';
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
  bool _searchOpen = false;
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

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (_searchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchOpen) _searchFocus.requestFocus();
      });
    } else {
      _searchFocus.unfocus();
      _searchController.clear();
      _applyQuery('');
    }
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
    return ReaderSettingsSheetFrame(
      preset: preset,
      title: '目录',
      closeTooltip: '关闭',
      scrollKey: const ValueKey('reader-directory-scroll'),
      maxHeightFactor: MediaQuery.viewInsetsOf(context).bottom > 0 ? 1 : .86,
      actions: [
        GlassIconButton(
          key: const ValueKey('reader-catalogue-search-toggle'),
          icon: CupertinoIcons.search,
          label: _searchOpen ? '收起搜索' : '搜索目录',
          onPressed: _toggleSearch,
        ),
        Tooltip(
          message: _reversed ? '切换为正序' : '切换为倒序',
          child: GlassTextButton(
            key: const ValueKey('reader-catalogue-order'),
            compact: true,
            selected: _reversed,
            onPressed: _toggleOrder,
            child: Text(_reversed ? '倒序' : '正序'),
          ),
        ),
      ],
      // 目录是长列表，用有界 body 让列表自己滚动：软键盘弹起时列表底边
      // 停在键盘上沿，而不是把整块内容继续往下铺到键盘下面。
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : WenkuMotion.enter,
              alignment: Alignment.topCenter,
              child: _searchOpen
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                      child: AppSearchField(
                        inputKey: const ValueKey('reader-chapter-search'),
                        controller: _searchController,
                        focusNode: _searchFocus,
                        hint: '搜索章节名或输入章序',
                        clearTooltip: '清空',
                        onChanged: _onSearchChanged,
                        onSubmitted: _applyQuery,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            if (currentValid && _query.isEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 12, 2),
                  child: TextButton.icon(
                    onPressed: _locateCurrent,
                    icon: const ArchiveIcon(
                      CupertinoIcons.location_fill,
                      size: 16,
                    ),
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
              ),
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
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
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

  Widget _row(BuildContext context, int index, ReaderThemePreset preset) {
    final chapter = widget.chapters[index];
    final current = index == widget.currentIndex;
    final cached = widget.cachedIds.contains(chapter.itemId);
    return ListTile(
      key: ValueKey('reader-directory-row-$index'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      minLeadingWidth: 38,
      horizontalTitleGap: 8,
      minTileHeight: _itemExtent - 4,
      titleAlignment: ListTileTitleAlignment.center,
      selected: current,
      selectedColor: preset.accentColor,
      selectedTileColor: preset.textColor.withValues(alpha: 0.06),
      textColor: preset.textColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
      ),
      onTap: () => Navigator.pop(context, index),
      leading: SizedBox(
        width: 38,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('${index + 1}', style: const TextStyle(fontSize: 12)),
        ),
      ),
      title: Text(
        chapter.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, height: 1.45),
      ),
      trailing: current || cached
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (current) const Text('正在阅读', style: TextStyle(fontSize: 10)),
                if (cached)
                  const Tooltip(
                    message: '已缓存',
                    child: ArchiveIcon(CupertinoIcons.checkmark_seal, size: 16),
                  ),
              ],
            )
          : null,
    );
  }
}
