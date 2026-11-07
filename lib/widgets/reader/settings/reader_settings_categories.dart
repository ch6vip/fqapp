// Geometry and card-origin reveal ported from Wenku8_Flutter ebcd7f1,
// lib/reader_tools.dart:1034-1220 and _CategoryRevealClipper:2152.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../wenku/wenku_ui.dart';

class ReaderSettingsCategory {
  const ReaderSettingsCategory(this.id, this.title, this.icon, this.summary);
  final String id, title, summary;
  final IconData icon;
}

class ReaderSettingsCategoryGrid extends StatelessWidget {
  const ReaderSettingsCategoryGrid({
    super.key,
    required this.categories,
    required this.onSelected,
    this.reduceMotion = false,
  });
  final List<ReaderSettingsCategory> categories;
  final void Function(String, Rect?) onSelected;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final textScale = scaler.scale(16) / 16;
      final minimumCardWidth = scaler.scale(16) * 2 + 56;
      var columns = constraints.maxWidth >= 620 ? 4 : 2;
      while (columns > 1 &&
          (constraints.maxWidth - (columns - 1) * 10) / columns <
              minimumCardWidth) {
        columns = columns == 4 ? 2 : 1;
      }
      return GridView.builder(
        key: const ValueKey('reader-settings-category-grid'),
        padding: EdgeInsets.zero,
        primary: false,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: categories.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          mainAxisExtent: 104 + math.max(0, textScale - 1) * 64,
        ),
        itemBuilder: (context, index) {
          final item = categories[index];
          return Builder(
            builder: (tileContext) {
              void open() {
                final tile = tileContext.findRenderObject();
                onSelected(
                  item.id,
                  tile is RenderBox && tile.hasSize
                      ? tile.localToGlobal(Offset.zero) & tile.size
                      : null,
                );
              }

              final card = DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: .42),
                  borderRadius: BorderRadius.circular(18),
                  border: MediaQuery.highContrastOf(context)
                      ? Border.all(color: Theme.of(context).colorScheme.outline)
                      : null,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(item.icon, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.title,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        item.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
              final key = ValueKey('reader-settings-category-${item.id}');
              if (reduceMotion) {
                return InkWell(
                  key: key,
                  onTap: open,
                  borderRadius: BorderRadius.circular(18),
                  child: card,
                );
              }
              return JellyTapSurface(key: key, onTap: open, child: card);
            },
          );
        },
      );
    },
  );
}

class ReaderCategoryRevealClipper extends CustomClipper<Path> {
  const ReaderCategoryRevealClipper(
    this.origin,
    this.coordinateSpace,
    this.progress,
  );
  final Rect? origin;
  final GlobalKey coordinateSpace;
  final double progress;

  @override
  Path getClip(Size size) {
    final bounds = Offset.zero & size;
    final body = coordinateSpace.currentContext?.findRenderObject();
    // Resolve after layout, while the bottom-anchored panel grows upward.
    final start = origin != null && body is RenderBox && body.hasSize
        ? body.globalToLocal(origin!.topLeft) & origin!.size
        : bounds;
    return Path()..addRRect(
      RRect.fromRectAndRadius(
        Rect.lerp(start, bounds, progress)!,
        Radius.circular(18 * (1 - progress)),
      ),
    );
  }

  @override
  bool shouldReclip(ReaderCategoryRevealClipper oldClipper) =>
      origin != oldClipper.origin || progress != oldClipper.progress;
}

class ReaderAdjustmentPlate extends CustomPainter {
  const ReaderAdjustmentPlate(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).inflate(12),
        const Radius.circular(16),
      ),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(ReaderAdjustmentPlate oldDelegate) =>
      color != oldDelegate.color;
}
