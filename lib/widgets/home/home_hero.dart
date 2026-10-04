import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// A compact masthead leaves the first screen to the actual stories.
class HomeHero extends StatelessWidget {
  final VoidCallback onSearch;
  final VoidCallback onRanks;
  final Future<void> Function() onRefresh;
  final bool refreshing;

  const HomeHero({
    super.key,
    required this.onSearch,
    required this.onRanks,
    required this.onRefresh,
    this.refreshing = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(14);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF6954), HomePalette.accent],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: [
                    BoxShadow(
                      color: HomePalette.accent.withValues(alpha: 0.28),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(
                  LucideIcons.book_open,
                  color: Colors.white,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '番茄小铺',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '好故事，不止一种',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.muted,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              if (scale <= 20)
                ExcludeSemantics(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: HomePalette.accent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          LucideIcons.sparkles,
                          color: HomePalette.accent,
                          size: 13,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '每日发现',
                          style: TextStyle(
                            color: HomePalette.accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: HomePressable(
                  key: const Key('home_search_button'),
                  onTap: onSearch,
                  semanticLabel: '搜索小说、短剧、漫剧、漫画和听书',
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: palette.soft,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: palette.line.withValues(alpha: 0.5),
                        width: 0.6,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.search,
                          size: 17,
                          color: palette.muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '搜索你想看的故事',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: palette.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '排行榜',
                child: IconButton(
                  key: const Key('home_ranks_button'),
                  onPressed: onRanks,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    fixedSize: const Size(44, 44),
                    foregroundColor: palette.ink,
                    backgroundColor: palette.surface,
                    side: BorderSide(
                      color: palette.line.withValues(alpha: 0.7),
                      width: 0.8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: EdgeInsets.zero,
                  ),
                  icon: const Icon(LucideIcons.trophy, size: 18),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: '刷新推荐',
                child: IconButton(
                  key: const Key('home_refresh_button'),
                  onPressed: refreshing ? null : onRefresh,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    fixedSize: const Size(44, 44),
                    foregroundColor: palette.ink,
                    backgroundColor: palette.surface,
                    side: BorderSide(
                      color: palette.line.withValues(alpha: 0.7),
                      width: 0.8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: EdgeInsets.zero,
                  ),
                  icon: refreshing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: HomePalette.accent,
                          ),
                        )
                      : const Icon(LucideIcons.refresh_ccw, size: 18),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
