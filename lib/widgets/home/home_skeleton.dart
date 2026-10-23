import 'package:flutter/material.dart';

import 'home_design.dart';

/// First-load skeleton, ported from `res/layout/cmc.xml`.
///
/// The official bookstore paints three stacked placeholder groups while the
/// first page is in flight (`alx.xml` points `SkeletonLayout` at `cmc`):
///
/// ```
/// cmc  (root: skin_color_bg_f6_light, i.e. #F6F6F6)
/// ├─ cn   clr : one row of six 12dp bars, equal width, 12dp apart
/// │             (the category strip placeholder), 12dp side margins
/// ├─ ggj  clm : a white card, 24dp top / 20dp bottom / 16dp side padding
/// │   ├─ 64x12 title bar + 40x12 bar on the right (title + 「更多」)
/// │   └─ two columns × four rows, each row 44x62 cover + two text bars
/// │      (cm1.xml), 18dp apart
/// └─ e17  cli : two side-by-side 355dp-tall white cards (clh.xml)
/// ```
///
/// Upstream breathes via `SkeletonLayout`, not a shimmer sweep, so the pulse is
/// an opacity cycle in `[0.6, 1.0]`.
///
/// This replaces the spinners that used to sit here. A spinner tells the user
/// nothing about what is coming; the official skeleton at least keeps the page
/// from jumping when the real blocks land.
class HomeSkeleton extends StatefulWidget {
  const HomeSkeleton({super.key});

  @override
  State<HomeSkeleton> createState() => _HomeSkeletonState();
}

class _HomeSkeletonState extends State<HomeSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Respect the OS "remove animations" setting: no pulse, just the shapes.
    final animate = !MediaQuery.disableAnimationsOf(context);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        _CategoryRow(),
        _BlockSkeleton(),
        _CardPairSkeleton(),
      ],
    );
    if (!animate) return body;
    return FadeTransition(
      // 0.6 -> 1.0, matching SkeletonLayout's breathing alpha.
      opacity: Tween<double>(begin: 0.6, end: 1).animate(
        CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
      ),
      child: body,
    );
  }
}

/// `clr.xml` — six equal bars standing in for the category strip.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (var i = 0; i < 6; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            const Expanded(child: _Bar(height: 12)),
          ],
        ],
      ),
    );
  }
}

/// `clm.xml` — the block card: title bars, then two columns × four rows.
class _BlockSkeleton extends StatelessWidget {
  const _BlockSkeleton();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 18, left: 12, right: 12),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 20),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              _Bar(width: 64, height: 12),
              Spacer(),
              _Bar(width: 40, height: 12),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var column = 0; column < 2; column++) ...[
                if (column > 0) const SizedBox(width: 26),
                const Expanded(child: _SkeletonRows()),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Four `cm1.xml` rows: 44x62 cover plus two text bars, 18dp apart.
class _SkeletonRows extends StatelessWidget {
  const _SkeletonRows();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var row = 0; row < 4; row++) ...[
          if (row > 0) const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _Bar(width: 44, height: 62),
              SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Bar(height: 12),
                    SizedBox(height: 8),
                    FractionallySizedBox(
                      widthFactor: 0.5,
                      alignment: Alignment.centerLeft,
                      child: _Bar(height: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// `cli.xml` + `clh.xml` — two 355dp white cards side by side, 8dp apart.
class _CardPairSkeleton extends StatelessWidget {
  const _CardPairSkeleton();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    Widget card() => Container(
      height: 355,
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(8),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      child: Row(
        children: [
          Expanded(child: card()),
          const SizedBox(width: 8),
          Expanded(child: card()),
        ],
      ),
    );
  }
}

/// One placeholder bar. Colour is a fixed light grey rather than a palette
/// token: the official rects are neutral grey at low alpha on a white card.
class _Bar extends StatelessWidget {
  const _Bar({required this.height, this.width});

  final double height;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFEDEDED),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}
