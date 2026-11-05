import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/media_item.dart';
import '../../services/app_theme.dart';
import '../../services/poster_cache.dart';
import '../home/home_archive.dart' show einkCoverFilter;

/// The cover pipeline shared by the archive carousel, the shelf tiles and the
/// existing `bookshelf_card` cards. It keeps fqapp's single poster cache,
/// file/svg local covers and the e-ink grayscale treatment.
///
/// Upstream `NovelCover` loads through `LegacyCover`/`LocalBookMedia`
/// (`W/lib/app_ui.dart:1531-1748`). Those are a second cache; fqapp maps the
/// remote path to `PosterCache` and the local path to direct file reads.

bool isRemoteCover(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

/// Decoded pixel width for a logical [width], matching the upstream cap.
int shelfCoverDecodeWidth(double width, double devicePixelRatio) =>
    (width * devicePixelRatio).ceil().clamp(1, 1536);

/// The [ImageProvider] used for remote and raster file covers.
///
/// SVG covers cannot be decoded by `Image`; [ShelfCoverImage] renders those
/// with `SvgPicture.file`. Empty values and SVGs therefore throw here.
ImageProvider<Object> shelfCoverImageProvider(
  String url,
  double width,
  double devicePixelRatio,
) {
  final value = url.trim();
  final decodeWidth = shelfCoverDecodeWidth(width, devicePixelRatio);
  if (isRemoteCover(value)) {
    return CachedNetworkImageProvider(
      value,
      cacheManager: PosterCache.instance,
      maxWidth: decodeWidth,
    );
  }
  if (value.isEmpty || _isSvgPath(value)) {
    throw ArgumentError.value(
      url,
      'url',
      'No image provider for an empty or SVG cover',
    );
  }
  return ResizeImage.resizeIfNeeded(decodeWidth, null, FileImage(File(value)));
}

/// Warms the poster for [url] at the same resolution the face will use.
/// Local covers and SVGs are skipped: there is no cache entry to warm.
Future<void> precacheShelfCover(
  BuildContext context,
  String url,
  double width, {
  double? devicePixelRatio,
}) async {
  final value = url.trim();
  if (!isRemoteCover(value)) return;
  final ratio = devicePixelRatio ?? MediaQuery.devicePixelRatioOf(context);
  try {
    await precacheImage(
      shelfCoverImageProvider(value, width, ratio),
      context,
      onError: (_, _) {},
    );
  } catch (_) {
    // The visible face keeps its normal error/retry path.
  }
}

File? _coverFile(String value) {
  final path = value.toLowerCase().startsWith('file://')
      ? Uri.tryParse(value)?.toFilePath() ?? ''
      : value;
  return path.isEmpty ? null : File(path);
}

bool _isSvgPath(String value) {
  final path = value.toLowerCase().startsWith('file://')
      ? Uri.tryParse(value)?.path ?? value
      : value;
  return path.toLowerCase().endsWith('.svg');
}

/// Archive fallback face for books without a usable cover.
class ShelfCoverFallback extends StatelessWidget {
  const ShelfCoverFallback({
    super.key,
    required this.item,
    required this.width,
    required this.height,
  });
  final MediaItem item;
  final double width, height;

  static const Key coverKey = Key('shelf-cover-fallback');

  @override
  Widget build(BuildContext context) {
    final colors = switch (item.kind) {
      'video' => const [Color(0xFF734740), Color(0xFF242428)],
      'manju' => const [Color(0xFF8B557E), Color(0xFF35283D)],
      'manga' => const [Color(0xFF6F6887), Color(0xFF343349)],
      'audio' => const [Color(0xFF426C78), Color(0xFF233B42)],
      _ => const [Color(0xFF6A7964), Color(0xFF293C35)],
    };
    final titleSize = (width * .13).clamp(12.0, 22.0);
    return SizedBox(
      key: coverKey,
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: const Alignment(-0.34, -0.94),
            end: const Alignment(0.34, 0.94),
            colors: colors,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(math.max(8, width * .1)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                item.title.trim().isEmpty ? '未命名作品' : item.title.trim(),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: titleSize,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 8),
              if (item.author.trim().isNotEmpty)
                Text(
                  item.author.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .75),
                    fontSize: width * .085,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders one shelf cover: remote posters through [PosterCache], local
/// raster files, SVG files, the e-ink grayscale filter and a caller-provided
/// fallback.
class ShelfCoverImage extends StatelessWidget {
  const ShelfCoverImage({
    super.key,
    required this.item,
    required this.width,
    required this.height,
    this.fallback,
    this.fit = BoxFit.cover,
    this.radius = 0,
    this.decodeWidth,
  });
  final MediaItem item;
  final double width, height;
  final Widget? fallback;
  final BoxFit fit;
  final double radius;
  final int? decodeWidth;

  @override
  Widget build(BuildContext context) {
    final placeholder = fallback ?? _fallback();
    final value = item.cover.trim();
    final decode =
        decodeWidth ??
        shelfCoverDecodeWidth(width, MediaQuery.devicePixelRatioOf(context));
    final Widget art;
    if (value.isEmpty) {
      art = placeholder;
    } else if (isRemoteCover(value)) {
      art = CachedNetworkImage(
        cacheManager: PosterCache.instance,
        imageUrl: value,
        fit: fit,
        memCacheWidth: decode,
        fadeInDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 150),
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    } else {
      final file = _coverFile(value);
      if (file == null) {
        art = placeholder;
      } else if (_isSvgPath(value)) {
        art = SvgPicture.file(
          file,
          fit: fit,
          placeholderBuilder: (_) => placeholder,
        );
      } else {
        art = Image.file(
          file,
          fit: fit,
          cacheWidth: decode,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => placeholder,
        );
      }
    }
    Widget result = SizedBox(width: width, height: height, child: art);
    if (einkModeNotifier.value) {
      result = ColorFiltered(colorFilter: einkCoverFilter, child: result);
    }
    if (radius > 0) {
      result = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: result,
      );
    }
    return result;
  }

  Widget _fallback() =>
      ShelfCoverFallback(item: item, width: width, height: height);
}
