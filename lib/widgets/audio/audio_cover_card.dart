import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/audio_page_theme.dart';
import '../../services/poster_cache.dart';

class AudioCoverImage extends StatelessWidget {
  final String url;

  const AudioCoverImage({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    if (url.isEmpty) {
      return ColoredBox(
        color: theme.card,
        child: Icon(LucideIcons.book_open, color: theme.muted, size: 36),
      );
    }
    return ColoredBox(
      color: theme.card,
      child: CachedNetworkImage(
        cacheManager: PosterCache.instance,
        imageUrl: url,
        fit: BoxFit.contain,
        memCacheWidth: 640,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (context, _) => ColoredBox(color: theme.card),
        errorWidget: (context, _, _) => ColoredBox(
          color: theme.card,
          child: Icon(LucideIcons.book_open, color: theme.muted, size: 36),
        ),
      ),
    );
  }
}
