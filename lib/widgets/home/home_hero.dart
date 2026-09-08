import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// Editorial hero header for the home feed: brand row, oversized display
/// typography, the search entry, and a scroll-driven marquee strip.
///
/// All motion here is driven by the feed's scroll offset (no infinite
/// tickers), so the page settles completely when idle.
class HomeHero extends StatelessWidget {
  final ScrollController scroll;
  final VoidCallback onSearch;
  final Future<void> Function() onRefresh;

  const HomeHero({
    super.key,
    required this.scroll,
    required this.onSearch,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: scroll,
      builder: (context, child) {
        final offset = scroll.hasClients ? scroll.offset : 0.0;
        final fade = (1 - offset / 260).clamp(0.0, 1.0);
        // The header lags behind the scroll for a parallax feel, then fades.
        final lag = math.min(offset, 400) * 0.22;
        return Opacity(
          opacity: fade,
          child: Transform.translate(offset: Offset(0, lag), child: child),
        );
      },
      child: RepaintBoundary(
        child: _HeroBody(
          scroll: scroll,
          onSearch: onSearch,
          onRefresh: onRefresh,
        ),
      ),
    );
  }
}

/// Static hero content. Rebuilt only when the theme changes; scroll motion is
/// applied by the wrapping [AnimatedBuilder].
class _HeroBody extends StatelessWidget {
  final ScrollController scroll;
  final VoidCallback onSearch;
  final Future<void> Function() onRefresh;

  const _HeroBody({
    required this.scroll,
    required this.onSearch,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  LucideIcons.sparkles,
                  size: 14,
                  color: scheme.onPrimary,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '番茄小铺',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'FQ STUDIO',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Container(width: 22, height: 1, color: scheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'DAILY CURATED FEED — NO.09',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '发现',
                    style: TextStyle(
                      fontSize: 62,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                      color: scheme.onSurface,
                    ),
                  ),
                  TextSpan(
                    text: '新大陆',
                    style: TextStyle(
                      fontSize: 62,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                      foreground: Paint()
                        ..style = PaintingStyle.stroke
                        ..strokeWidth = 1.4
                        ..color = scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '短剧 · 小说 · 漫画 · 听书，一座每日更新的内容宇宙',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(child: _SearchPill(onTap: onSearch)),
              const SizedBox(width: 10),
              _RefreshButton(onRefresh: onRefresh),
            ],
          ),
        ),
        const SizedBox(height: 24),
        HomeMarquee(scroll: scroll),
      ],
    );
  }
}

/// Tappable fake search input; tapping opens the search page.
class _SearchPill extends StatelessWidget {
  final VoidCallback onTap;

  const _SearchPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(26),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.search, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '搜索短剧、小说、漫画...',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  LucideIcons.arrow_up_right,
                  size: 15,
                  color: scheme.onPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Round bordered refresh trigger sitting beside the search pill.
class _RefreshButton extends StatelessWidget {
  final Future<void> Function() onRefresh;

  const _RefreshButton({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(26),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
      ),
      child: InkWell(
        onTap: onRefresh,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            key: const Key('home_refresh_button'),
            LucideIcons.refresh_ccw,
            size: 19,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// Scroll-driven marquee strip. Translation is a pure function of the feed's
/// scroll offset, so no ticker runs while the page is idle.
class HomeMarquee extends StatefulWidget {
  final ScrollController scroll;

  const HomeMarquee({super.key, required this.scroll});

  @override
  State<HomeMarquee> createState() => _HomeMarqueeState();
}

class _HomeMarqueeState extends State<HomeMarquee> {
  static const _phrases = [
    (LucideIcons.book_open, '小说 NOVELS'),
    (LucideIcons.clapperboard, '短剧 DRAMAS'),
    (LucideIcons.image, '漫画 COMICS'),
    (LucideIcons.headphones, '听书 AUDIO'),
  ];

  final GlobalKey _unitKey = GlobalKey();
  double _unitWidth = 0;

  void _measure() {
    final width = _unitKey.currentContext?.size?.width ?? 0;
    if (width > 0 && width != _unitWidth && mounted) {
      setState(() => _unitWidth = width);
    }
  }

  Widget _unit(ColorScheme scheme, {Key? key}) {
    return Row(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (icon, label) in _phrases) ...[
          const SizedBox(width: 22),
          Icon(icon, size: 13, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 2.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(width: 22),
          Icon(
            LucideIcons.asterisk,
            size: 12,
            color: scheme.primary.withValues(alpha: 0.7),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    return AnimatedBuilder(
      animation: widget.scroll,
      builder: (context, _) {
        final offset = widget.scroll.hasClients ? widget.scroll.offset : 0.0;
        final dx = _unitWidth > 0 ? -(offset * 0.6) % _unitWidth : 0.0;
        return Container(
          height: 38,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
                width: 0.5,
              ),
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
                width: 0.5,
              ),
            ),
          ),
          child: ClipRect(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final copies = _unitWidth > 0
                    ? (constraints.maxWidth / _unitWidth).ceil() + 2
                    : 1;
                // OverflowBox gives the row unbounded width so paint clipping
                // (not a layout error) trims the offscreen copies.
                return OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: double.infinity,
                  child: Transform.translate(
                    offset: Offset(dx, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < copies; i++)
                          _unit(scheme, key: i == 0 ? _unitKey : null),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
