import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';
import '../home/home_media_card.dart';

/// 3:4 detail cover with a soft shadow, tappable to open the zoomable viewer.
class DetailCoverTile extends StatelessWidget {
  final MediaItem item;

  /// 桌面两栏布局：封面放大到 168×224。
  final bool desktop;
  final bool compact;

  const DetailCoverTile({
    super.key,
    required this.item,
    this.desktop = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // The cover keeps its 3:4 ratio; it only grows a little with text scale so
    // the text column is never starved of width.
    final width =
        (desktop ? (compact ? 112.0 : 168.0) : 92.0) +
        (scaler.scale(16) - 16).clamp(0.0, 10.0) * 1.2;
    return SizedBox(
      width: width,
      child: HomePressable(
        key: const Key('detail_cover_button'),
        semanticLabel: '查看《${item.title}》封面',
        onTap: () => showDetailCover(context, item),
        borderRadius: BorderRadius.circular(6),
        child: ExcludeSemantics(
          child: AspectRatio(
            aspectRatio: 3 / 4,
            child: _CoverArt(item: item, palette: palette),
          ),
        ),
      ),
    );
  }
}

class _CoverArt extends StatelessWidget {
  final MediaItem item;
  final HomePalette palette;

  const _CoverArt({required this.item, required this.palette});

  @override
  Widget build(BuildContext context) {
    final cover = StoryCover(item: item, cacheWidth: 320);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: palette.dark ? 0.42 : 0.14),
            blurRadius: 14,
            spreadRadius: -2,
            offset: const Offset(1, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            palette.eink
                ? ColorFiltered(
                    colorFilter: const ColorFilter.matrix(<double>[
                      0.2126, 0.7152, 0.0722, 0, 0, //
                      0.2126, 0.7152, 0.0722, 0, 0, //
                      0.2126, 0.7152, 0.0722, 0, 0, //
                      0, 0, 0, 1, 0, //
                    ]),
                    child: cover,
                  )
                : cover,
            if (!palette.eink)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 10,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withValues(alpha: 0.22),
                        Colors.white.withValues(alpha: 0.14),
                        Colors.transparent,
                      ],
                      stops: const [0, 0.32, 1],
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: palette.eink
                        ? palette.line
                        : Colors.white.withValues(
                            alpha: palette.dark ? 0.16 : 0.28,
                          ),
                    width: 0.8,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen zoomable cover viewer. Tapping the cover opens it.
Future<void> showDetailCover(BuildContext context, MediaItem item) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭封面',
      barrierColor: Colors.black.withValues(alpha: 0.92),
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: IconButton(
                    tooltip: '关闭封面',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(LucideIcons.x, color: Colors.white),
                  ),
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  key: const Key('detail_cover_viewer'),
                  maxScale: 3,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: AspectRatio(
                          aspectRatio: 5 / 7,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: StoryCover(item: item, cacheWidth: 1000),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
                child: Text(
                  item.title,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
