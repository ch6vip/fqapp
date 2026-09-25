import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/poster_cache.dart';

/// The same cover is used during loading and while swiping adjacent pages.
/// A bounded decode avoids keeping a full-resolution poster per page.
class PlayerCover extends StatelessWidget {
  final String url;
  final String? label;
  final bool loading;

  const PlayerCover({
    super.key,
    required this.url,
    this.label,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF27242C), Color(0xFF101014)],
          ),
        ),
      ),
      if (url.isNotEmpty)
        CachedNetworkImage(
          cacheManager: PosterCache.instance,
          imageUrl: url,
          fit: BoxFit.cover,
          memCacheWidth: 720,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          placeholder: (context, url) => const SizedBox.expand(),
          errorWidget: (context, url, error) => const SizedBox.expand(),
        ),
      const ColoredBox(color: Color(0x88000000)),
      if (loading || label != null)
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading) ...[
                  const SizedBox.square(
                    dimension: 26,
                    child: CircularProgressIndicator(
                      color: Colors.white70,
                      strokeWidth: 2,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (label != null)
                  Text(
                    label!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
              ],
            ),
          ),
        ),
    ],
  );
}
