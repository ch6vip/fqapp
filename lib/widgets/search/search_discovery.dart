import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/search_discovery.dart';
import '../home/home_design.dart';

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
    return Material(
      color: palette.surface,
      child: ListView.separated(
        key: const Key('search_suggestions'),
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: suggestions.length,
        separatorBuilder: (context, _) =>
            Divider(height: 1, color: palette.line, indent: 52),
        itemBuilder: (context, index) {
          final suggestion = suggestions[index];
          return InkWell(
            key: ValueKey('search_suggestion_${suggestion.text}'),
            onTap: () => onSelect(suggestion.text),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: palette.soft,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(LucideIcons.search, size: 13, color: palette.muted),
                  ),
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
          );
        },
      ),
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
class HotSearchBoard extends StatelessWidget {
  final HotSearch hot;
  final ValueChanged<String> onSelect;

  const HotSearchBoard({super.key, required this.hot, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (hot.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: palette.line,
            width: 0.6,
          ),
          boxShadow: [
            BoxShadow(
              color: palette.ink.withValues(alpha: palette.dark ? 0.12 : 0.03),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: HomePalette.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(LucideIcons.flame, size: 15, color: HomePalette.accent),
                ),
                const SizedBox(width: 8),
                Text(
                  '热搜榜',
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              key: const Key('search_hot_words'),
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < hot.words.length; i++)
                  _HotChip(
                    word: hot.words[i],
                    rank: i + 1,
                    hot: i < 3,
                    onTap: () => onSelect(hot.words[i]),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HotChip extends StatelessWidget {
  final String word;
  final int rank;
  final bool hot;
  final VoidCallback onTap;

  const _HotChip({
    required this.word,
    required this.rank,
    required this.hot,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      key: ValueKey('search_hot_$word'),
      semanticLabel: '搜索 $word',
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: hot
              ? HomePalette.accent.withValues(alpha: palette.dark ? 0.16 : 0.08)
              : palette.soft,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: hot
                ? HomePalette.accent.withValues(alpha: 0.28)
                : palette.line,
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hot) ...[
              Container(
                width: 15,
                height: 15,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: HomePalette.accent,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$rank',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              word,
              style: TextStyle(
                color: hot ? palette.accentText : palette.ink,
                fontSize: 12.5,
                fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
