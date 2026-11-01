import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/chapter_media.dart';
import '../../services/audio_floating_routes.dart';
import '../home/home_design.dart';
import 'comic_image_tile.dart';

/// 漫画大图查看器（点单页进入，可双指缩放）。
///
/// chrome 跟随 [HomePalette]：浅色白底、深色近黑、墨水屏纯白；关闭键用
/// Lucide x。官方 PreviewImageActivity 会隐藏悬浮播放胶囊，这里保持。
class ComicImageViewer extends StatelessWidget {
  final ComicImage image;
  final int pageNumber;
  final double aspectRatio;
  final ImageProvider<Object> Function(ComicImage image)? providerFactory;

  const ComicImageViewer({
    super.key,
    required this.image,
    required this.pageNumber,
    required this.aspectRatio,
    this.providerFactory,
  });

  @override
  Widget build(BuildContext context) {
    AudioFloatingRouteScope.configure(context, hidden: true);
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        foregroundColor: palette.ink,
        elevation: 0,
        title: Text('第 $pageNumber 页', style: TextStyle(color: palette.ink)),
        leading: IconButton(
          tooltip: '关闭大图',
          color: palette.ink,
          icon: const Icon(LucideIcons.x, size: 22),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return InteractiveViewer(
              key: const ValueKey('comic-image-zoom'),
              constrained: false,
              minScale: 1,
              maxScale: 5,
              child: SizedBox(
                width: width,
                height: math.max(width / aspectRatio, constraints.maxHeight),
                child: ComicImageTile(
                  image: image,
                  pageNumber: pageNumber,
                  providerFactory: providerFactory,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
