import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import 'home_design.dart';
import 'home_media_card.dart';

/// The day's featured stories.
///
/// Each page is a split editorial card: a quiet portrait cover on the left and
/// a short, readable story note on the right. The previous full-bleed image
/// stack carried a type badge, score, title, metadata and a button on top of the
/// artwork; that has been reduced to one image and one clear reading direction.
class HomeSpotlight extends StatefulWidget {
  final List<MediaItem> items;
  final ValueChanged<MediaItem> onOpen;
  final String title;

  const HomeSpotlight({
    super.key,
    required this.items,
    required this.onOpen,
    this.title = '今日焦点',
  });

  @override
  State<HomeSpotlight> createState() => _HomeSpotlightState();
}

class _HomeSpotlightState extends State<HomeSpotlight> {
  final _pages = PageController();
  int _active = 0;

  @override
  void didUpdateWidget(HomeSpotlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_active >= widget.items.length ||
        (oldWidget.items.isNotEmpty &&
            widget.items.isNotEmpty &&
            oldWidget.items.first.id != widget.items.first.id)) {
      _active = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients) _pages.jumpToPage(0);
      });
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() {
    if (!_pages.hasClients || widget.items.length < 2) return;
    final next = (_active + 1) % widget.items.length;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(next);
    } else {
      _pages.animateToPage(
        next,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final palette = HomePalette.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final height = 218.0 + (scale - 1).clamp(0.0, 2.0) * 78;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HomeSpace.gutter,
            16,
            HomeSpace.gutter,
            10,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textScaler: MediaQuery.textScalerOf(
                    context,
                  ).clamp(maxScaleFactor: 1.4),
                  style: HomeType.section.copyWith(color: palette.primary),
                ),
              ),
              if (widget.items.length > 1)
                _PageSwitch(
                  index: _active,
                  count: widget.items.length,
                  palette: palette,
                  onNext: _next,
                ),
            ],
          ),
        ),
        SizedBox(
          height: height,
          child: PageView.builder(
            key: const Key('home_spotlight_pages'),
            controller: _pages,
            padEnds: false,
            allowImplicitScrolling: true,
            physics: const PageScrollPhysics(),
            itemCount: widget.items.length,
            onPageChanged: (value) => setState(() => _active = value),
            itemBuilder: (context, index) {
              final item = widget.items[index];
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HomeSpace.gutter,
                ),
                child: _SpotlightCard(
                  item: item,
                  onTap: () => widget.onOpen(item),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Compact page counter that doubles as the next-page action.
class _PageSwitch extends StatelessWidget {
  final int index;
  final int count;
  final HomePalette palette;
  final VoidCallback onNext;

  const _PageSwitch({
    required this.index,
    required this.count,
    required this.palette,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '下一条推荐，第 ${index + 1} 条，共 $count 条',
      excludeSemantics: true,
      child: InkWell(
        key: const Key('home_spotlight_next'),
        onTap: onNext,
        borderRadius: BorderRadius.circular(10),
        splashColor: HomePalette.accent.withValues(alpha: 0.07),
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${index + 1} / $count',
                style: HomeType.figure.copyWith(color: palette.tertiary),
              ),
              const SizedBox(width: 4),
              Icon(
                LucideIcons.chevron_right,
                size: 14,
                color: palette.tertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpotlightCard extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  const _SpotlightCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final palette = HomePalette.of(context);
    final tint = HomeKindTint.of(item.kind, eink: palette.eink);
    final action = switch (item.kind) {
      'video' => '开始追剧',
      'manju' => '观看漫剧',
      'audio' => '开始听书',
      'manga' => '翻开漫画',
      _ => '立即阅读',
    };
    final meta = [
      if (item.score case final score?) score.toStringAsFixed(1),
      if (item.author.isNotEmpty) item.author,
      if (item.ep.isNotEmpty) item.ep,
    ].join('  ·  ');

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverHeight = math.max(120.0, constraints.maxHeight - 24);
        final idealWidth = coverHeight * 5 / 7;
        final widthCap =
            constraints.maxWidth * (constraints.maxWidth >= 560 ? 0.28 : 0.40);
        final coverWidth = math
            .min(idealWidth, widthCap)
            .clamp(96.0, 196.0)
            .toDouble();

        return HomePressable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          pressedScale: 0.988,
          semanticLabel: '${item.title}，$action',
          child: Container(
            clipBehavior: Clip.antiAlias,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: palette.line.withValues(
                  alpha: palette.dark ? 0.7 : 0.65,
                ),
                width: 0.8,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: coverWidth,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 5 / 7,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: StoryCover(
                          item: item,
                          cacheWidth: (coverWidth * pixelRatio).ceil(),
                          alignment: Alignment.topCenter,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        homeKindLabel(item.kind),
                        textScaler: MediaQuery.textScalerOf(
                          context,
                        ).clamp(maxScaleFactor: 1.4),
                        style: HomeType.eyebrow.copyWith(
                          color: palette.eink ? Colors.black : tint,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textScaler: MediaQuery.textScalerOf(
                          context,
                        ).clamp(maxScaleFactor: 1.5),
                        style: TextStyle(
                          fontSize: 22,
                          height: 1.18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.45,
                          color: palette.ink,
                        ),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HomeType.meta.copyWith(color: palette.muted),
                        ),
                      ],
                      const Spacer(),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              action,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textScaler: MediaQuery.textScalerOf(
                                context,
                              ).clamp(maxScaleFactor: 1.4),
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: palette.accentText,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Icon(
                            LucideIcons.arrow_right,
                            size: 14,
                            color: palette.accentText,
                          ),
                        ],
                      ),
                    ],
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
