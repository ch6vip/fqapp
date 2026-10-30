import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/media_item.dart' show Chapter;
import '../home/home_cell_blocks.dart' show HomeBlockMore;
import '../home/home_design.dart';
import '../player/story_player_panel.dart' show episodeTileLabel;
import 'series_detail_common.dart';
import 'series_detail_theme.dart';

/// 选集：紧贴播放钮下方，50 集一段、可倒序，6 列格子。
///
/// 版式稿：区块头 15sp + 右端 12sp 状态；分段胶囊 12sp；格子高 34、
/// 圆角 8、间距 6；一段先给 24 格，下面居中的「展开 25–50 集」再放全部。
/// 目录失败只在本区块内联重试，播放钮保持自己的状态。
class SeriesDetailEpisodes extends StatefulWidget {
  const SeriesDetailEpisodes({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.watched,
    required this.initialRange,
    required this.pageSize,
    required this.statusText,
    required this.hasRelatedSeries,
    required this.onOpenRelatedSeries,
    required this.loading,
    required this.failed,
    required this.onRetry,
    required this.onSelect,
  });

  /// 一段先展示的格子数（版式稿 4 行 × 6 列）。
  static const collapsedCount = 24;

  final List<Chapter> episodes;
  final int currentIndex;
  final Set<int> watched;

  /// 当前集所在的段，由页面按播放进度算好。
  final int initialRange;
  final int pageSize;
  final String? statusText;
  final bool hasRelatedSeries;
  final VoidCallback onOpenRelatedSeries;
  final bool loading;
  final bool failed;
  final VoidCallback onRetry;
  final ValueChanged<int> onSelect;

  @override
  State<SeriesDetailEpisodes> createState() => _SeriesDetailEpisodesState();
}

class _SeriesDetailEpisodesState extends State<SeriesDetailEpisodes> {
  static const _columns = 6;

  late int _range = widget.initialRange;
  bool _reversed = false;
  bool _expanded = false;
  int? _revealedRange;
  final ScrollController _rangeScroll = ScrollController();
  final GlobalKey _selectedRangeKey = GlobalKey();

  int get _rangeCount => widget.episodes.isEmpty
      ? 0
      : (widget.episodes.length - 1) ~/ widget.pageSize + 1;

  @override
  void didUpdateWidget(SeriesDetailEpisodes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialRange != oldWidget.initialRange ||
        widget.episodes.length != oldWidget.episodes.length) {
      _range = widget.initialRange;
      _expanded = false;
    }
  }

  @override
  void dispose() {
    _rangeScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final rangeCount = _rangeCount;
    final range = rangeCount == 0 ? 0 : _range.clamp(0, rangeCount - 1);
    return SeriesSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SeriesSectionHeader(title: '选集', action: _headerAction(palette)),
          widget.episodes.isEmpty
              ? _emptyBody(palette)
              : _catalogBody(palette, range, rangeCount),
        ],
      ),
    );
  }

  // ---- 头部右侧 ----

  Widget? _headerAction(HomePalette palette) {
    final status = widget.statusText;
    if (status == null && !widget.hasRelatedSeries) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status != null)
          Flexible(
            child: Text(
              status,
              key: const ValueKey('series-episode-status'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ),
        if (status != null && widget.hasRelatedSeries)
          Text(' · ', style: TextStyle(fontSize: 12, color: palette.muted)),
        if (widget.hasRelatedSeries)
          HomeBlockMore(
            key: const ValueKey('series-detail-related-series'),
            onTap: widget.onOpenRelatedSeries,
            label: '同系列',
          ),
      ],
    );
  }

  // ---- 空 / 失败 ----

  Widget _emptyBody(HomePalette palette) {
    if (widget.loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            key: const ValueKey('series-episodes-loading'),
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.muted,
            ),
          ),
        ),
      );
    }
    if (widget.failed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SeriesRetryInline(
          message: '剧集加载失败',
          action: '重试加载',
          actionKey: const ValueKey('series-episodes-retry'),
          onRetry: widget.onRetry,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          '暂无剧集',
          key: const ValueKey('series-episodes-empty'),
          style: TextStyle(fontSize: 13, color: palette.muted),
        ),
      ),
    );
  }

  // ---- 目录 ----

  Widget _catalogBody(HomePalette palette, int range, int rangeCount) {
    final start = range * widget.pageSize;
    final end = (start + widget.pageSize).clamp(0, widget.episodes.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rangeCount > 1) ...[
          _rangeStrip(palette, range, rangeCount),
          const SizedBox(height: 10),
        ],
        _grid(palette, _order(start, end)),
        if (!_expanded && end - start > SeriesDetailEpisodes.collapsedCount)
          _expandLink(palette, start, end),
      ],
    );
  }

  List<int> _order(int start, int end) {
    final order = [for (var i = start; i < end; i++) i];
    if (_reversed) order.setAll(0, order.reversed.toList());
    if (!_expanded && order.length > SeriesDetailEpisodes.collapsedCount) {
      return order.take(SeriesDetailEpisodes.collapsedCount).toList();
    }
    return order;
  }

  Widget _expandLink(HomePalette palette, int start, int end) =>
      GestureDetector(
        key: const ValueKey('series-episodes-expand'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = true),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '展开 ${start + SeriesDetailEpisodes.collapsedCount + 1}–$end 集',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ),
        ),
      );

  Widget _rangeStrip(HomePalette palette, int range, int rangeCount) {
    _revealSelectedRange(range);
    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            key: const ValueKey('series-episode-pages'),
            controller: _rangeScroll,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var page = 0; page < rangeCount; page++)
                  _rangeChip(palette, page, page == range),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        _reverseToggle(palette),
      ],
    );
  }

  Widget _rangeChip(HomePalette palette, int page, bool selected) => Container(
    key: selected ? _selectedRangeKey : null,
    margin: const EdgeInsets.only(right: 6),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        _range = page;
        _expanded = false;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? palette.ink : palette.soft,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          '${page * widget.pageSize + 1}–'
          '${((page + 1) * widget.pageSize).clamp(0, widget.episodes.length)}',
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            fontWeight: selected ? FontWeight.w500 : FontWeight.normal,
            color: selected ? palette.canvas : palette.muted,
          ),
        ),
      ),
    ),
  );

  Widget _reverseToggle(HomePalette palette) {
    final color = _reversed ? palette.accentText : palette.muted;
    return Semantics(
      button: true,
      selected: _reversed,
      label: '倒序',
      child: GestureDetector(
        key: const ValueKey('series-episode-reverse'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _reversed = !_reversed),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_vert_rounded, size: 14, color: color),
            const SizedBox(width: 2),
            Text(
              '倒序',
              style: TextStyle(fontSize: 12, height: 1.5, color: color),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前段可能在第 5 屏之外，把分段条横向滚到它；只动分段条。
  void _revealSelectedRange(int range) {
    if (_revealedRange == range) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _revealedRange == range) return;
      final target = _selectedRangeKey.currentContext?.findRenderObject();
      if (target is! RenderBox || !target.attached || !target.hasSize) return;
      _revealedRange = range;
      if (!_rangeScroll.hasClients) return;
      unawaited(
        _rangeScroll.position.ensureVisible(
          target,
          alignment: 0.5,
          duration: const Duration(milliseconds: 160),
        ),
      );
    });
  }

  // ---- 网格 ----

  Widget _grid(HomePalette palette, List<int> order) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final columns = ((constraints.maxWidth + 6) / (44 * scale + 6))
          .floor()
          .clamp(3, _columns);
      return GridView.builder(
        key: const ValueKey('series-episode-grid'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          mainAxisExtent: 34 * scale,
        ),
        itemCount: order.length,
        itemBuilder: (context, position) => _tile(palette, order[position]),
      );
    },
  );

  /// 格子：已看灰字，当前集强调色描边 + 浅强调底 + 强调色文字；
  /// 墨水屏当前集实心纯黑、白字，其余格子黑描边。
  Widget _tile(HomePalette palette, int index) {
    final episode = widget.episodes[index];
    final isCurrent = index == widget.currentIndex;
    final watched = widget.watched.contains(index);
    final Color textColor;
    if (episode.disabled) {
      textColor = palette.muted.withValues(alpha: 0.5);
    } else if (isCurrent) {
      textColor = seriesAccentText(palette);
    } else if (watched) {
      textColor = palette.muted;
    } else {
      textColor = palette.ink;
    }
    final BorderSide border;
    if (palette.eink) {
      border = BorderSide(color: palette.ink);
    } else {
      border = isCurrent
          ? BorderSide(color: seriesAccent(palette))
          : const BorderSide(color: Colors.transparent);
    }
    return Semantics(
      key: ValueKey('series-episode-$index'),
      label: '第 ${index + 1} 集',
      button: true,
      selected: isCurrent,
      enabled: !episode.disabled,
      excludeSemantics: true,
      onTap: episode.disabled ? null : () => widget.onSelect(index),
      child: Material(
        color: isCurrent ? seriesCurrentFill(palette) : palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          side: border,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: episode.disabled ? null : () => widget.onSelect(index),
          child: Center(
            child: Text(
              episodeTileLabel(
                index: index,
                trailer: episode.trailer,
                highlight: episode.highlight,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: isCurrent && !episode.disabled
                    ? FontWeight.w500
                    : FontWeight.normal,
                color: textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
