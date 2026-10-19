import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home_design.dart';

/// The home masthead.
///
/// The refresh action now lives in pull-to-refresh. Keeping only search and the
/// rank shortcut in the utility row gives the page one clear action hierarchy
/// instead of three equally weighted buttons.
class HomeHero extends StatelessWidget {
  final VoidCallback onSearch;
  final VoidCallback onRanks;

  /// Small issue/date label. Kept as editorial texture, not as a second title.
  final String issue;

  const HomeHero({
    super.key,
    required this.onSearch,
    required this.onRanks,
    this.issue = '今日刊',
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final largeType = scaler.scale(13) > 18;
    final displayScaler = scaler.clamp(maxScaleFactor: 1.35);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeSpace.gutter,
        8,
        HomeSpace.gutter,
        8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  gradient: palette.eink
                      ? null
                      : const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFFF6B54), HomePalette.accent],
                        ),
                  color: palette.eink ? Colors.black : null,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  LucideIcons.book_open,
                  size: 14,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                'FQ',
                textScaler: scaler.clamp(maxScaleFactor: 1.2),
                style: TextStyle(
                  fontSize: 15,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  color: palette.ink,
                ),
              ),
              const SizedBox(width: 7),
              Container(width: 1, height: 11, color: palette.line),
              const SizedBox(width: 7),
              Text(
                '发现',
                textScaler: scaler.clamp(maxScaleFactor: 1.2),
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.8,
                  color: palette.muted,
                ),
              ),
              const Spacer(),
              if (!largeType)
                Text(
                  issue,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textScaler: scaler.clamp(maxScaleFactor: 1.2),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                    color: palette.tertiary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            '今天，读点好的。',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textScaler: displayScaler,
            style: HomeType.display.copyWith(color: palette.primary),
          ),
          const SizedBox(height: 8),
          Text(
            '小说、短剧、漫画和听书，都在这里。',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textScaler: displayScaler,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              letterSpacing: 0.1,
              color: palette.muted,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: HomePressable(
                  key: const Key('home_search_button'),
                  onTap: onSearch,
                  borderRadius: BorderRadius.circular(16),
                  semanticLabel: '搜索书、剧或作者',
                  pressedScale: 0.985,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
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
                            '搜索书、剧或作者',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textScaler: scaler.clamp(maxScaleFactor: 1.25),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
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
                message: '排行榜',
                child: Material(
                  color: palette.soft,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    key: const Key('home_ranks_button'),
                    onTap: onRanks,
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(
                        LucideIcons.trophy,
                        size: 18,
                        color: palette.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
