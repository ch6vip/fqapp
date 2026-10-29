import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/search_discovery.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';

// 搜索页的发现区：联想词、热搜榜、搜索历史。
//
// 2026-10-30 与首页统一：不再用「白卡 + 描边 + 阴影」的模板盒子，改成分区
// 头 + 16dp 栏距的裸排；热搜仍是可点的胶囊，但去掉彩色图标底和边框，
// 前三名只留一个强调色数字。

/// Suggestion list shown while the query is being typed.
///
/// Renders nothing when there is nothing to suggest, so the field simply has no
/// dropdown rather than an empty panel.
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
        thickness: 0.5,
        color: palette.line,
        indent: homeGutter + 24,
        endIndent: homeGutter,
      ),
      itemBuilder: (context, index) {
        final suggestion = suggestions[index];
        return InkWell(
          key: ValueKey('search_suggestion_${suggestion.text}'),
          onTap: () => onSelect(suggestion.text),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: homeGutter,
              vertical: 13,
            ),
            child: Row(
              children: [
                Icon(LucideIcons.search, size: 14, color: palette.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: _SuggestionText(
                    suggestion: suggestion,
                    palette: palette,
                  ),
                ),
              ],
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
/// 与首页的分区同一个语法：19sp 标题 + 16dp 栏距 + 可点的胶囊。前三名的
/// 名次是一个强调色数字，不是带底色的圆点。
class HotSearchBoard extends StatelessWidget {
  final HotSearch hot;
  final ValueChanged<String> onSelect;

  const HotSearchBoard({super.key, required this.hot, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    if (hot.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HomeSectionHeader(title: '热搜榜'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Wrap(
            key: const Key('search_hot_words'),
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < hot.words.length; i++)
                _HotChip(
                  word: hot.words[i],
                  rank: i + 1,
                  onTap: () => onSelect(hot.words[i]),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HotChip extends StatelessWidget {
  final String word;
  final int rank;
  final VoidCallback onTap;

  const _HotChip({required this.word, required this.rank, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final hot = rank <= 3;
    return HomePressable(
      key: ValueKey('search_hot_$word'),
      semanticLabel: '搜索 $word',
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: palette.soft,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hot) ...[
              Text(
                '$rank',
                style: const TextStyle(
                  color: HomePalette.accent,
                  fontSize: 12,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              word,
              style: TextStyle(
                color: palette.ink,
                fontSize: 13,
                height: 1.3,
                fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空查询时的发现区：热搜榜 + 搜索历史，两段裸排，不套白卡。
class SearchDiscoveryView extends StatelessWidget {
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
    final palette = HomePalette.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (hot.isNotEmpty) HotSearchBoard(hot: hot, onSelect: onSearch),
        HomeSectionHeader(
          title: '搜索历史',
          action: history.isEmpty
              ? null
              : TextButton(
                  onPressed: onClearHistory,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
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
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: _historyBody(context),
        ),
      ],
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

  /// 一条搜索记录：整块可点重新搜索，右端 × 只删这一条。
  Widget _historyChip(BuildContext context, String query) {
    final palette = HomePalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => onSearch(query),
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(999),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
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
          Tooltip(
            message: '删除 $query',
            child: InkWell(
              onTap: () => onRemoveHistory(query),
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(2, 8, 10, 8),
                child: Icon(LucideIcons.x, size: 13, color: palette.muted),
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
