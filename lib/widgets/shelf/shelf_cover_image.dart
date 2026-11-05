import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../models/media_item.dart';
import '../../services/app_theme.dart';
import '../../services/poster_cache.dart';
import '../home/home_archive.dart' show einkCoverFilter;
import '../wenku/wenku_archive.dart' show ArchiveDesign;
import '../wenku/wenku_theme.dart' show WenkuTheme;

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
/// with `SvgPicture.file`.
///
/// Throws [ArgumentError] when [url] is empty or names an `.svg`: callers that
/// handle arbitrary covers must use [ShelfCoverImage] (which branches first),
/// or check [isRemoteCover]/the extension themselves. Never call this for a
/// blank placeholder.
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
///
/// Matches upstream `NovelCover`'s fallback (`W/lib/app_ui.dart:1624-1662`
/// with the `accent` container at `:1714-1733`): a flat `#202020` plate, the
/// shared 3dp cover radius, `width * .11` padding, a white `width * .16` title
/// and a `width * .085` author. No per-kind tint: decisions #10 asks for the
/// upstream archive look on every shelf surface.
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
    final title = item.title.trim();
    return SizedBox(
      key: coverKey,
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ArchiveDesign.coverRadius),
        child: ColoredBox(
          color: WenkuTheme.accent,
          child: Padding(
            padding: EdgeInsets.all(width * .11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  title.isEmpty ? '未命名作品' : title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: width * .16,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 8),
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
