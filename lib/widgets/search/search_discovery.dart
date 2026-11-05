import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/search_discovery.dart';
import '../home/home_archive.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';

// 搜索页的发现区：联想词、热搜榜、搜索历史。
//
// Archive sections keep titles separate from badges and popularity metadata.

/// Suggestion list shown while the query is being typed.
///
/// Renders nothing when there is nothing to suggest, so the field simply has no
/// dropdown rather than an empty panel. 行高 48dp，分隔线两端都落在 16dp 栏距上。
class SearchSuggestionList extends StatelessWidget {
  final List<SearchSuggestion> suggestions;
  final ValueChanged<String> onSelect;

  const SearchSuggestionList({
    super.key,
    required this.suggestions,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return ListView.separated(
      key: const Key('search_suggestions'),
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: 4),
      itemCount: suggestions.length,
      separatorBuilder: (context, _) => Divider(
        height: 1,
        thickness: 1,
        color: palette.line,
        indent: homeGutter,
        endIndent: homeGutter,
      ),
      itemBuilder: (context, index) {
        final suggestion = suggestions[index];
        return InkWell(
          key: ValueKey('search_suggestion_${suggestion.text}'),
          onTap: () => onSelect(suggestion.text),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: homeGutter),
              child: Row(
                children: [
                  Icon(LucideIcons.search, size: 14, color: palette.muted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SuggestionText(
                      suggestion: suggestion,
                      palette: palette,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The upstream marks the matched part with `<em>`; keep that emphasis rather
/// than dropping it, since it shows why a suggestion matched.
class _SuggestionText extends StatelessWidget {
  final SearchSuggestion suggestion;
  final HomePalette palette;

  const _SuggestionText({required this.suggestion, required this.palette});

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(color: palette.ink, fontSize: 14);
    final marked = base.copyWith(
      color: palette.accentText,
      fontWeight: FontWeight.w600,
    );
    final parts = _splitHighlight(suggestion.highlighted);
    if (parts.isEmpty) {
      return Text(
        suggestion.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    return RichText(
      maxLines: 1,
      textScaler: MediaQuery.textScalerOf(context),
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: base,
        children: [
          for (final part in parts)
            TextSpan(text: part.$1, style: part.$2 ? marked : base),
        ],
      ),
    );
  }

  /// Splits `<em>x</em>` into (text, isHighlighted) runs; the tags are dropped.
  static List<(String, bool)> _splitHighlight(String raw) {
    if (raw.isEmpty || !raw.contains('<em>')) return const [];
    final out = <(String, bool)>[];
    var rest = raw;
    while (rest.isNotEmpty) {
      final start = rest.indexOf('<em>');
      if (start < 0) {
        out.add((rest, false));
        break;
      }
      if (start > 0) out.add((rest.substring(0, start), false));
      final end = rest.indexOf('</em>', start);
      if (end < 0) {
        out.add((rest.substring(start + 4), true));
        break;
      }
      out.add((rest.substring(start + 4, end), true));
      rest = rest.substring(end + 5);
    }
    return out.where((part) => part.$1.isNotEmpty).toList();
  }
}

/// The hot search board, shown when the query is empty.
///
/// 榜单来自官方 472 热搜榜（最多 50 条），空查询页只铺前十：名次、词、
/// 角标（巅峰榜/热聊…）、热搜值。前三名的名次用强调色，其余用次级色，
/// 不画圆点底、不套白卡，和首页的分区同一个语法。
class HotSearchBoard extends StatelessWidget {
  /// How many rows the empty search screen shows.
  static const maxRows = 10;

  final HotSearch hot;
  final ValueChanged<String> onSelect;

  const HotSearchBoard({super.key, required this.hot, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    if (hot.isEmpty) return const SizedBox.shrink();
    final entries = hot.entries.take(maxRows).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HomeSectionLabel(code: 'TRENDING', title: '热搜榜'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Column(
            key: const Key('search_hot_words'),
            children: [
              for (var i = 0; i < entries.length; i++)
                _HotRow(
                  entry: entries[i],
                  rank: i + 1,
                  onTap: () => onSelect(entries[i].title),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HotRow extends StatelessWidget {
  final HotSearchEntry entry;
  final int rank;
  final VoidCallback onTap;

  const _HotRow({required this.entry, required this.rank, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final top = rank <= 3;
    return HomePressable(
      key: ValueKey('search_hot_${entry.title}'),
      semanticLabel: '搜索 ${entry.title}',
      onTap: onTap,
      borderRadius: BorderRadius.circular(homePanelRadius),
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 36,
              child: HomeCode(
                rank.toString().padLeft(2, '0'),
                size: 14,
                color: top ? palette.accentText : palette.muted,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.ink,
                      fontSize: 14,
                      height: 1.4,
                      fontWeight: top ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (entry.badge.isNotEmpty || entry.hotValue.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (entry.badge.isNotEmpty)
                          _HotBadge(text: entry.badge),
                        if (entry.hotValue.isNotEmpty)
                          Text(
                            entry.hotValue,
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 榜单角标（巅峰榜 / 热聊 / 新 …）。统一的次级底色，不给每种角标配一套
/// 颜色——官方那套渐变在这里只会变成噪音。
class _HotBadge extends StatelessWidget {
  final String text;

  const _HotBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: palette.muted,
          fontSize: 9.5,
          height: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 空查询时的发现区：搜索历史在前，热搜榜在后，两段裸排，不套白卡。
///
/// 搜索历史的位置比热搜更靠前，所以输入前就能看到；输入中只保留按输入过滤
/// 后的历史（[filter] 非空时热搜整块隐藏），不再闪回热搜榜。
class SearchDiscoveryView extends StatelessWidget {
  /// 内容区第一行（工具条）；联想词 / 输入过滤状态下不传。
  final Widget? leading;

  final HotSearch hot;
  final List<String> history;
  final bool historyLoading;

  /// 输入框里的文字（已归一化成小写），用来过滤历史。
  final String filter;
  final ValueChanged<String> onSearch;
  final VoidCallback onClearHistory;
  final ValueChanged<String> onRemoveHistory;

  const SearchDiscoveryView({
    super.key,
    this.leading,
    required this.hot,
    required this.history,
    required this.historyLoading,
    required this.filter,
    required this.onSearch,
    required this.onClearHistory,
    required this.onRemoveHistory,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.only(
        bottom: 24 + MediaQuery.paddingOf(context).bottom,
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        ?leading,
        _historyHeader(context),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: _historyBody(context),
        ),
        if (filter.isEmpty && hot.isNotEmpty)
          HotSearchBoard(hot: hot, onSelect: onSearch),
      ],
    );
  }

  Widget _historyHeader(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomeSectionLabel(
      code: 'HISTORY',
      title: '搜索历史',
      action: history.isEmpty
          ? null
          : TextButton(
              onPressed: onClearHistory,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: palette.muted,
              ),
              child: const Text(
                '清空',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                ),
              ),
            ),
    );
  }

  Widget _historyBody(BuildContext context) {
    final visible = filter.isEmpty
        ? history
        : history
              .where((item) => item.toLowerCase().contains(filter))
              .toList(growable: false);
    if (historyLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (history.isEmpty) return _message(context, '暂无搜索历史');
    if (visible.isEmpty) return _message(context, '没有匹配的搜索记录');
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final query in visible) _historyChip(context, query)],
    );
  }

  /// Search and removal retain separate, full-height hit targets.
  Widget _historyChip(BuildContext context, String query) {
    final palette = HomePalette.of(context);
    return Container(
      key: ValueKey('search_history_$query'),
      height: math.max(
        44,
        MediaQuery.textScalerOf(context).scale(12.5) * 1.2 + 16,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(homePanelRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.min(220, MediaQuery.sizeOf(context).width - 88),
            ),
            child: InkWell(
              onTap: () => onSearch(query),
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(homePanelRadius),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    query,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.2,
                      color: palette.ink,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          SizedBox(
            width: 44,
            height: double.infinity,
            child: Tooltip(
              message: '删除 $query',
              child: InkWell(
                onTap: () => onRemoveHistory(query),
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(homePanelRadius),
                ),
                child: Center(
                  child: Icon(LucideIcons.x, size: 13, color: palette.muted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _message(BuildContext context, String text) {
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            color: HomePalette.of(context).muted,
          ),
        ),
      ),
    );
  }
}
