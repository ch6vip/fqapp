import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import 'home_design.dart';
import 'home_media_card.dart';

/// A finite, user-controlled carousel: only live recommendations are shown.
class HomeSpotlight extends StatefulWidget {
  final List<MediaItem> items;
  final ValueChanged<MediaItem> onOpen;
  const HomeSpotlight({
    super.key,
    required this.items,
    required this.onOpen,
  });

  @override
  State<HomeSpotlight> createState() => _HomeSpotlightState();
}

class _HomeSpotlightState extends State<HomeSpotlight> {
  final _pages = PageController(viewportFraction: 0.94);
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
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final palette = HomePalette.of(context);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final scale = MediaQuery.textScalerOf(context).scale(28) / 28;
    final height = 244.0 + (scale - 1).clamp(0.0, 2.0) * 95;
    final current = (_active + 1).toString().padLeft(2, '0');
    final total = widget.items.length.toString().padLeft(2, '0');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: '此刻，'),
                      const TextSpan(
                        text: '入迷',
                        style: TextStyle(color: HomePalette.accent),
                      ),
                      TextSpan(
                        text: '。',
                        style: TextStyle(color: palette.ink),
                      ),
                    ],
                  ),
                  textScaler: MediaQuery.textScalerOf(
                    context,
                  ).clamp(maxScaleFactor: 1.35),
                  style: TextStyle(
                    fontSize: 30,
                    height: 1.1,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.2,
                    color: palette.ink,
                  ),
                ),
              ),
              if (scale < 1.5)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '总有一个故事，正合你意',
                    style: TextStyle(fontSize: 10, color: palette.muted),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.only(left: 20),
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
                return AnimatedBuilder(
                  animation: _pages,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _SpotlightCard(
                      item: item,
                      index: index,
                      onTap: () => widget.onOpen(item),
                    ),
                  ),
                  builder: (context, child) {
                    final page =
                        _pages.hasClients &&
                            _pages.position.hasContentDimensions
                        ? _pages.page ?? _active.toDouble()
                        : _active.toDouble();
                    final distance = (page - index).clamp(-1.0, 1.0);
                    return Transform.scale(
                      scale: reducedMotion ? 1 : 1 - distance.abs() * 0.045,
                      alignment: Alignment.centerLeft,
                      child: child,
                    );
                  },
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 16, 0),
          child: Row(
            children: [
              if (scale < 1.5) ...[
                const Icon(
                  LucideIcons.sparkles,
                  color: HomePalette.accent,
                  size: 13,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '为你精选，随心发现',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: palette.muted),
                  ),
                ),
                const SizedBox(width: 12),
                if (widget.items.length > 1)
                  ExcludeSemantics(
                    child: Row(
                      children: [
                        for (var i = 0; i < widget.items.length; i++)
                          AnimatedContainer(
                            duration: reducedMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 220),
                            margin: const EdgeInsets.only(right: 4),
                            width: i == _active ? 18 : 4,
                            height: 4,
                            decoration: BoxDecoration(
                              color: i == _active
                                  ? HomePalette.accent
                                  : palette.line,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(width: 10),
              ],
              Flexible(
                flex: scale >= 1.5 ? 1 : 0,
                fit: scale >= 1.5 ? FlexFit.tight : FlexFit.loose,
                child: Semantics(
                  liveRegion: true,
                  label: '第 $current 条，共 $total 条推荐',
                  excludeSemantics: true,
                  child: Text(
                    '$current / $total',
                    key: const Key('home_spotlight_page'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.muted,
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              if (widget.items.length > 1)
                IconButton(
                  key: const Key('home_spotlight_next'),
                  tooltip: '下一条推荐',
                  onPressed: _next,
                  icon: Icon(
                    LucideIcons.arrow_right,
                    size: 17,
                    color: palette.ink,
                  ),
                  constraints: const BoxConstraints.tightFor(
                    width: 44,
                    height: 44,
                  ),
                  padding: EdgeInsets.zero,
                )
              else
                const SizedBox(height: 44),
            ],
          ),
        ),
      ],
    );
  }
}

class _SpotlightCard extends StatelessWidget {
  final MediaItem item;
  final int index;
  final VoidCallback onTap;

  const _SpotlightCard({
    required this.item,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final action = switch (item.kind) {
      'video' => '开始追剧',
      'manju' => '观看漫剧',
      'audio' => '开始听书',
      'manga' => '翻开漫画',
      _ => '立即阅读',
    };
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              fit: StackFit.expand,
              children: [
                StoryCover(
                  item: item,
                  cacheWidth: (constraints.maxWidth * pixelRatio).ceil(),
                  alignment: Alignment.topCenter,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, 0.27, 0.65, 1],
                      colors: [
                        Color(0x350C1513),
                        Color(0x180C1513),
                        Color(0xBA0C1513),
                        Color(0xF50C1513),
                      ],
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0x50000000), Color(0x00000000)],
                    ),
                  ),
                ),
                Positioned(
                  left: 18,
                  top: 18,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.25),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          homeKindIcon(item.kind),
                          size: 13,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          homeKindLabel(item.kind),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Container(width: 1, height: 9, color: Colors.white38),
                        const SizedBox(width: 7),
                        const Text(
                          '精选',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            height: 1.1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (scaler.scale(14) < 21)
                  Positioned(
                    right: 14,
                    top: 4,
                    child: ExcludeSemantics(
                      child: Text(
                        (index + 1).toString().padLeft(2, '0'),
                        style: TextStyle(
                          fontSize: 78,
                          height: 1.1,
                          fontWeight: FontWeight.w900,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          foreground: Paint()
                            ..style = PaintingStyle.stroke
                            ..strokeWidth = 0.8
                            ..color = Colors.white.withValues(alpha: 0.42),
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          height: 1.14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.6,
                          shadows: [
                            Shadow(color: Colors.black26, blurRadius: 12),
                          ],
                        ),
                      ),
                      if (item.author.isNotEmpty || item.ep.isNotEmpty) ...[
                        const SizedBox(height: 9),
                        Text(
                          [
                            if (item.author.isNotEmpty) item.author,
                            if (item.ep.isNotEmpty) item.ep,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.76),
                            fontSize: 11,
                            height: 1.3,
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  action,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    height: 1.1,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF252923),
                                  ),
                                ),
                                const SizedBox(width: 9),
                                const Icon(
                                  LucideIcons.arrow_up_right,
                                  size: 15,
                                  color: Color(0xFF252923),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
