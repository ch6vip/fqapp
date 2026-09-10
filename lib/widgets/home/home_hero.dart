import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// A compact masthead leaves the first screen to the actual stories.
class HomeHero extends StatelessWidget {
  final VoidCallback onSearch;
  final Future<void> Function() onRefresh;
  final bool refreshing;

  const HomeHero({
    super.key,
    required this.onSearch,
    required this.onRefresh,
    this.refreshing = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: HomePalette.accent,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: HomePalette.accent.withValues(alpha: 0.18),
                      blurRadius: 16,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: const Icon(
                  LucideIcons.book_open,
                  color: Colors.white,
                  size: 23,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '番茄小铺',
                      style: TextStyle(
                        color: palette.ink,
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '好故事，不止一种',
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.muted,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
              ),
              if (MediaQuery.textScalerOf(context).scale(14) <= 20)
                ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Icon(
                        LucideIcons.sparkles,
                        color: HomePalette.accent,
                        size: 20,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '每日新发现',
                        style: TextStyle(color: palette.muted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: HomePressable(
                  key: const Key('home_search_button'),
                  onTap: onSearch,
                  semanticLabel: '搜索小说、短剧、漫剧、漫画和听书',
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 50),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      color: palette.soft,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.search,
                          size: 18,
                          color: palette.muted,
                        ),
                        const SizedBox(width: 10),
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
              const SizedBox(width: 10),
              Tooltip(
                message: '刷新推荐',
                child: IconButton(
                  key: const Key('home_refresh_button'),
                  onPressed: refreshing ? null : onRefresh,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(48, 50),
                    foregroundColor: palette.ink,
                    backgroundColor: palette.surface,
                    side: BorderSide(color: palette.line),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: const Icon(LucideIcons.refresh_ccw, size: 19),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
