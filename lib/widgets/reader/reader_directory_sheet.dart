// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/reader_catalogue.dart -> ReaderCatalogue (header, search toggle, order
//                                   control, current/cached row labels)
//
// fqapp keeps its own sheet route, debounced filtering, reversed projection,
// itemExtent and fast-scroll handle. Available Chapter.volumeName metadata now
// drives the upstream volume headers/collapse; a single unlabelled group stays
// flat. Display rows retain the original chapter indices in either order.
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
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../../services/ai_reading/ai_controller.dart';
import '../../services/ai_reading/ai_models.dart';
import '../../services/reader_preferences.dart';
import '../app_ui/app_ui_scope.dart';
import '../wenku/wenku_ui.dart';
import 'reader_directory_fast_scroll.dart';
import 'reader_theme.dart';
import 'settings/reader_settings_widgets.dart';

/// Searchable chapter directory using the current reading palette.
class ReaderDirectorySheet extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentIndex;
  final Set<String> cachedIds;
  final String bookId;
  final List<AiChapterCheckStatus> aiStatuses;
  final AiReadingController aiController;

  /// 阅读背景 preset：面板骨架、文字和控件配色都跟着它走。
  final ReaderThemePreset preset;

  const ReaderDirectorySheet({
    super.key,
    required this.chapters,
    required this.currentIndex,
    required this.cachedIds,
    required this.bookId,
    required this.aiStatuses,
    required this.aiController,
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
  late final Map<String, AiChapterCheckStatus> _aiStatuses;
  double _itemExtent = 60;
  int _scrollRevision = 0;
  bool _reversed = false;
  bool _searchOpen = false;
  String _query = '';
  final Set<String> _expandedVolumes = {};
  List<({String volume, int? chapter})> _rows = const [];

  /// One anchor chapter index per [_rows] entry for the fast-scroll handle.
  /// Kept as a stable field (not rebuilt per frame) so the handle keeps a drag
  /// alive when the live AI status list rebuilds the sheet.
  List<int> _rowAnchors = const [];

  void _resetGroups() {
    _expandedVolumes.clear();
    if (widget.currentIndex >= 0 &&
        widget.currentIndex < widget.chapters.length) {
      _expandedVolumes.add(widget.chapters[widget.currentIndex].volumeName);
    }
    _rebuildRows();
  }

  void _rebuildRows() {
    final groups = <String>{
      for (final chapter in widget.chapters) chapter.volumeName.trim(),
    };
    final grouped = groups.where((name) => name.isNotEmpty).length > 1;
    final rows = <({String volume, int? chapter})>[];
    String? previous;
    for (final index in _indexes) {
      final volume = widget.chapters[index].volumeName;
      if (grouped && volume.isNotEmpty && volume != previous) {
        rows.add((volume: volume, chapter: null));
      }
      if (!grouped ||
          volume.isEmpty ||
          _query.isNotEmpty ||
          _expandedVolumes.contains(volume)) {
        rows.add((volume: volume, chapter: index));
      }
      previous = volume;
    }
    _rows = rows;
    _rowAnchors = [
      for (final row in rows)
        row.chapter ??
            widget.chapters.indexWhere(
              (chapter) => chapter.volumeName == row.volume,
            ),
    ];
  }

  // The directory can hold thousands of chapters; filtering on every keystroke
  // re-scans them all and rebuilds the sheet. Coalesce the input instead.
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _aiStatuses = {
      for (final status in widget.aiStatuses) status.chapterId: status,
    };
    _indexes = _visibleIndexes;
    _resetGroups();
    widget.aiController.addListener(_onAiChanged);
    _schedulePosition(current: true);
  }

  void _onAiChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scaler = MediaQuery.textScalerOf(context);
    final titleBudget = scaler.scale(15) * 1.35 * 2 + 16;
    // Classic stacks the AI and cache markers; budget two lines of 11sp so a
    // large text scale cannot ask for more height than a fixed row allows.
    // Archive keeps exactly its previous extent.
    final markerBudget = AppUiScope.isClassic(context)
        ? scaler.scale(11) * 1.15 * 2 + 12
        : 0.0;
    final extent = math.max(60.0, math.max(titleBudget, markerBudget));
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
      _resetGroups();
      _schedulePosition(current: true);
    }
  }

  @override
  void dispose() {
    widget.aiController.removeListener(_onAiChanged);
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
      _rebuildRows();
    });
    _schedulePosition(current: _query.isEmpty);
  }

  void _locateCurrent() {
    _searchFocus.unfocus();
    _searchController.clear();
    if (widget.currentIndex >= 0 &&
        widget.currentIndex < widget.chapters.length) {
      _expandedVolumes.add(widget.chapters[widget.currentIndex].volumeName);
    }
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
          position ??
          (current
              ? _rows.indexWhere((row) => row.chapter == widget.currentIndex)
              : 0);
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
            chapter.volumeName.toLowerCase().contains(query) ||
            '${index + 1}'.contains(query);
      });
    }
    return indexes.toList(growable: false);
  }

  void _toggleOrder() {
    setState(() {
      _reversed = !_reversed;
      _indexes = _visibleIndexes;
      _rebuildRows();
    });
    _schedulePosition(current: _query.isEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    // One decision per build, from the live scope: classic restores the old
    // Material directory shell and rows, archive keeps the Wenku8 sheet.
    final classic = AppUiScope.isClassic(context);
    final currentValid =
        widget.currentIndex >= 0 &&
        widget.currentIndex < widget.chapters.length;
    return ReaderSettingsSheetFrame(
      preset: preset,
      title: classic ? '目录 · ${widget.chapters.length} 章' : '目录',
      closeTooltip: '关闭',
      scrollKey: const ValueKey('reader-directory-scroll'),
      maxHeightFactor: MediaQuery.viewInsetsOf(context).bottom > 0 ? 1 : .86,
      actions: classic
          ? const <Widget>[]
          : [
              GlassIconButton(
                key: const ValueKey('reader-catalogue-search-toggle'),
                icon: CupertinoIcons.search,
                label: _searchOpen ? '收起搜索' : '搜索目录',
                onPressed: _toggleSearch,
              ),
              _orderButton(preset, classic: false),
            ],
      // 目录是长列表，用有界 body 让列表自己滚动：软键盘弹起时列表底边
      // 停在键盘上沿，而不是把整块内容继续往下铺到键盘下面。
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            if (classic)
              _classicHeader(preset, constraints, currentValid)
            else ...[
              if (MediaQuery.disableAnimationsOf(context) || preset.isEink)
                _searchField()
              else
                AnimatedSize(
                  duration: WenkuMotion.enter,
                  alignment: Alignment.topCenter,
                  child: _searchField(),
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
            ],
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
                      indexes: _rowAnchors,
                      preset: preset,
                      child: ListView.builder(
                        key: const ValueKey('reader-directory-scroll'),
                        controller: _scrollController,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: classic
                            ? const EdgeInsets.symmetric(vertical: 8)
                            : const EdgeInsets.fromLTRB(10, 4, 10, 12),
                        itemExtent: _itemExtent,
                        itemCount: _rows.length,
                        itemBuilder: (context, position) =>
                            switch (_rows[position].chapter) {
                              final int index =>
                                classic
                                    ? _classicRow(context, index, preset)
                                    : _row(context, index, preset),
                              null =>
                                classic
                                    ? _classicVolumeRow(
                                        _rows[position].volume,
                                        preset,
                                      )
                                    : _volumeRow(
                                        _rows[position].volume,
                                        preset,
                                      ),
                            },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Classic header: always-visible search field with the order toggle, the
  /// chapter counter and 定位当前章, then a divider. Rows are skipped on very
  /// short panels (keyboard/landscape) so the list itself never loses room.
  Widget _classicHeader(
    ReaderThemePreset preset,
    BoxConstraints constraints,
    bool currentValid,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final searchHeight = math.max(48.0, scaler.scale(14) * 1.5 + 32) + 8;
    final statusHeight = math.max(48.0, scaler.scale(12) * 1.5 + 24);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (constraints.maxHeight >= searchHeight + 24)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                Expanded(child: _classicSearchField(preset)),
                const SizedBox(width: 8),
                _orderButton(preset, classic: true),
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
      ],
    );
  }

  Widget _orderButton(ReaderThemePreset preset, {required bool classic}) =>
      Tooltip(
        message: _reversed ? '切换为正序' : '切换为倒序',
        child: classic
            ? TextButton(
                key: const ValueKey('reader-catalogue-order'),
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
                      _reversed ? LucideIcons.arrow_up : LucideIcons.arrow_down,
                      size: 18,
                    ),
                    Text(
                      _reversed ? '倒序' : '正序',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              )
            : GlassTextButton(
                key: const ValueKey('reader-catalogue-order'),
                compact: true,
                selected: _reversed,
                onPressed: _toggleOrder,
                child: Text(_reversed ? '倒序' : '正序'),
              ),
      );

  Widget _classicSearchField(ReaderThemePreset preset) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _searchController,
        builder: (context, value, _) => TextField(
          key: const ValueKey('reader-chapter-search'),
          controller: _searchController,
          focusNode: _searchFocus,
          textInputAction: TextInputAction.search,
          style: TextStyle(color: preset.textColor, fontSize: 14),
          onChanged: _onSearchChanged,
          onSubmitted: _applyQuery,
          decoration: InputDecoration(
            hintText: '搜索章节名、卷名或章序',
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

  Widget _classicVolumeRow(String name, ReaderThemePreset preset) {
    final expanded = _query.isNotEmpty || _expandedVolumes.contains(name);
    final count = widget.chapters
        .where((chapter) => chapter.volumeName == name)
        .length;
    return Semantics(
      expanded: expanded,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Material(
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          color: preset.fieldColor,
          child: InkWell(
            key: ValueKey('reader-volume-$name'),
            onTap: _query.isNotEmpty
                ? null
                : () => setState(() {
                    if (!_expandedVolumes.add(name)) {
                      _expandedVolumes.remove(name);
                    }
                    _rebuildRows();
                  }),
            child: SizedBox(
              height: math.max(0.0, _itemExtent - 4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: preset.textColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '$count 章',
                      style: TextStyle(
                        fontSize: 11,
                        color: preset.mutedTextColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      expanded
                          ? LucideIcons.chevron_down
                          : LucideIcons.chevron_right,
                      size: 16,
                      color: preset.mutedTextColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _classicRow(
    BuildContext context,
    int index,
    ReaderThemePreset preset,
  ) {
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
            key: ValueKey('reader-directory-row-$index'),
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
            trailing: _classicTrailing(context, preset, chapter),
          ),
        ),
      ),
    );
  }

  /// Width the classic trailing column may take: the widest marker label at
  /// the current text scale, capped to a third of the row so the chapter title
  /// still reads on a 320dp screen.
  double _classicTrailingWidth(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    // Both marker labels are three CJK glyphs wide.
    final label = scaler.scale(11) * 3;
    final cap = MediaQuery.sizeOf(context).width * .3;
    return (label + 27).clamp(56.0, math.max(56.0, cap));
  }

  Widget _classicCacheWidget(
    ReaderThemePreset preset, {
    bool prominent = false,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: prominent ? 15 : 14,
        height: 11,
        child: Icon(
          Icons.download_outlined,
          size: prominent ? 13 : 12,
          color: preset.mutedTextColor,
        ),
      ),
      const SizedBox(width: 5),
      Flexible(
        child: Text(
          '已缓存',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: prominent ? 11 : 10,
            height: 1.1,
            color: preset.mutedTextColor,
          ),
        ),
      ),
    ],
  );

  Widget _classicStatusWidget(
    ReaderThemePreset preset,
    AiChapterCheckStatus status,
  ) {
    final eink = preset.isEink;
    final color = switch (status.state) {
      AiChapterCheckState.checked =>
        eink ? Colors.black : const Color(0xFF617348),
      AiChapterCheckState.failed =>
        eink ? Colors.black : const Color(0xFFAD4634),
      AiChapterCheckState.running => preset.accentColor,
      AiChapterCheckState.unchecked => preset.mutedTextColor,
    };
    final icon = switch (status.state) {
      AiChapterCheckState.checked => Icons.check_circle_outline,
      AiChapterCheckState.failed => Icons.error_outline,
      AiChapterCheckState.running => null,
      AiChapterCheckState.unchecked => null,
    };
    final label = switch (status.state) {
      AiChapterCheckState.checked => '已校验',
      AiChapterCheckState.failed => '失败',
      AiChapterCheckState.running => '校对中',
      AiChapterCheckState.unchecked => '未校验',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: status.state == AiChapterCheckState.running
              ? Padding(
                  padding: const EdgeInsets.all(1),
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: color,
                  ),
                )
              : Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1.15,
              color: color,
              fontWeight: status.state == AiChapterCheckState.running
                  ? FontWeight.w500
                  : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }

  Widget _classicTrailing(
    BuildContext context,
    ReaderThemePreset preset,
    Chapter chapter,
  ) {
    final status = _statusFor(chapter);
    final cached = widget.cachedIds.contains(chapter.itemId);
    final hasStatus = status != null;
    if (!hasStatus && !cached) return const SizedBox.shrink();
    final statusLine = hasStatus ? _classicStatusWidget(preset, status) : null;
    final cacheLine = cached
        ? Tooltip(
            message: '已缓存',
            child: _classicCacheWidget(preset, prominent: !hasStatus),
          )
        : null;
    // Intrinsic size instead of a fixed 64x30 box: at 2.0x text scale the old
    // box overflowed both axes inside ListTile. The Column is allowed to wrap
    // its labels within the same width the rows budgeted for it.
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: _classicTrailingWidth(context)),
      child: statusLine != null && cacheLine != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [statusLine, const SizedBox(height: 2), cacheLine],
            )
          : Align(
              alignment: Alignment.centerRight,
              child: statusLine ?? cacheLine,
            ),
    );
  }

  Widget _searchField() => _searchOpen
      ? Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: AppSearchField(
            inputKey: const ValueKey('reader-chapter-search'),
            controller: _searchController,
            focusNode: _searchFocus,
            hint: '搜索章节名、卷名或章序',
            clearTooltip: '清空',
            onChanged: _onSearchChanged,
            onSubmitted: _applyQuery,
          ),
        )
      : const SizedBox.shrink();

  Widget _volumeRow(String name, ReaderThemePreset preset) {
    final expanded = _query.isNotEmpty || _expandedVolumes.contains(name);
    final count = widget.chapters
        .where((chapter) => chapter.volumeName == name)
        .length;
    return Semantics(
      expanded: expanded,
      child: JellyTapSurface(
        key: ValueKey('reader-volume-$name'),
        onTap: _query.isNotEmpty
            ? null
            : () => setState(() {
                if (!_expandedVolumes.add(name)) _expandedVolumes.remove(name);
                _rebuildRows();
              }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: preset.textColor,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$count 章',
                style: TextStyle(fontSize: 11, color: preset.mutedTextColor),
              ),
              const SizedBox(width: 10),
              Icon(
                expanded
                    ? CupertinoIcons.chevron_down
                    : CupertinoIcons.chevron_right,
                size: 12,
              ),
            ],
          ),
        ),
      ),
    );
  }

  AiChapterCheckStatus? _statusFor(Chapter chapter) {
    final live = widget.aiController.statusFor(widget.bookId, chapter.itemId);
    if (live.running) {
      return AiChapterCheckStatus(
        bookId: widget.bookId,
        chapterId: chapter.itemId,
        chapterVersion: chapter.version,
        state: AiChapterCheckState.running,
        updatedAt: DateTime.now(),
      );
    }
    if (live.error != null) {
      return AiChapterCheckStatus(
        bookId: widget.bookId,
        chapterId: chapter.itemId,
        chapterVersion: chapter.version,
        state: AiChapterCheckState.failed,
        updatedAt: DateTime.now(),
      );
    }
    if (live.success || live.formal != null) {
      return AiChapterCheckStatus(
        bookId: widget.bookId,
        chapterId: chapter.itemId,
        chapterVersion: chapter.version,
        state: AiChapterCheckState.checked,
        updatedAt: DateTime.now(),
      );
    }
    final stored = _aiStatuses[chapter.itemId];
    if (stored == null || stored.state == AiChapterCheckState.unchecked) {
      return null;
    }
    if (stored.chapterVersion.isNotEmpty &&
        chapter.version.isNotEmpty &&
        stored.chapterVersion != chapter.version) {
      return null;
    }
    return stored;
  }

  Widget _statusWidget(ReaderThemePreset preset, AiChapterCheckStatus status) {
    final eink = preset.isEink;
    final color = switch (status.state) {
      AiChapterCheckState.checked =>
        eink ? Colors.black : const Color(0xFF617348),
      AiChapterCheckState.failed =>
        eink ? Colors.black : const Color(0xFFAD4634),
      AiChapterCheckState.running => preset.accentColor,
      AiChapterCheckState.unchecked => preset.mutedTextColor,
    };
    final icon = switch (status.state) {
      AiChapterCheckState.checked => CupertinoIcons.check_mark_circled,
      AiChapterCheckState.failed => CupertinoIcons.exclamationmark_circle,
      AiChapterCheckState.running => null,
      AiChapterCheckState.unchecked => null,
    };
    final label = switch (status.state) {
      AiChapterCheckState.checked => '已校验',
      AiChapterCheckState.failed => '失败',
      AiChapterCheckState.running => '校对中',
      AiChapterCheckState.unchecked => '未校验',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: status.state == AiChapterCheckState.running
              ? Padding(
                  padding: const EdgeInsets.all(1),
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: color,
                  ),
                )
              : Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            height: 1.15,
            color: color,
            fontWeight: status.state == AiChapterCheckState.running
                ? FontWeight.w500
                : FontWeight.w400,
          ),
        ),
      ],
    );
  }

  Widget? _trailingFor(
    ReaderThemePreset preset,
    Chapter chapter,
    bool current,
    bool cached,
  ) {
    final status = _statusFor(chapter);
    final lines = <Widget>[
      if (current) const Text('正在阅读', style: TextStyle(fontSize: 10)),
      if (status != null) _statusWidget(preset, status),
      if (cached) const Text('已缓存', style: TextStyle(fontSize: 10)),
    ];
    if (lines.isEmpty) return null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: lines,
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
      trailing: _trailingFor(preset, chapter, current, cached),
    );
  }
}
