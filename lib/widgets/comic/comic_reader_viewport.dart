import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/chapter_media.dart';
import '../../services/comic_page_layout.dart';
import 'comic_image_tile.dart';

/// 漫画页面视图：条漫（连续滚动）与翻页（PageView）两种模式。
///
/// 只负责版式与手势，进度记录、布局缓存和图片尺寸回调都由调用方持有，
/// 行为与拆分前保持一致（同一组 ValueKey 与滚动控制器）。
class ComicReaderViewport extends StatelessWidget {
  const ComicReaderViewport({
    super.key,
    required this.images,
    required this.generation,
    required this.pagedMode,
    required this.pageController,
    required this.ensurePageController,
    required this.scrollController,
    required this.layoutFor,
    required this.onPageChanged,
    required this.onImageReady,
    required this.onImageFailed,
    required this.onOpenImage,
    this.providerFactory,
  });

  final List<ComicImage> images;
  final int generation;
  final bool pagedMode;
  final PageController? pageController;

  /// 翻页模式第一次构建时创建 [PageController]（章节切换后会重置）。
  final PageController Function() ensurePageController;
  final ScrollController scrollController;
  final ComicPageLayout Function(double width) layoutFor;
  final ValueChanged<int> onPageChanged;
  final void Function(int index, int width, int height) onImageReady;
  final ValueChanged<int> onImageFailed;
  final ValueChanged<int> onOpenImage;
  final ImageProvider<Object> Function(ComicImage image)? providerFactory;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.min(math.max(constraints.maxWidth, 1.0), 900.0);
      final layout = layoutFor(width);
      if (pagedMode) {
        return _pagedView(width, pageController ?? ensurePageController());
      }
      return _stripView(width, layout);
    },
  );

  Widget _pagedView(double width, PageController controller) =>
      PageView.builder(
        key: const ValueKey('comic-reader-paged-view'),
        controller: controller,
        itemCount: images.length,
        onPageChanged: onPageChanged,
        itemBuilder: (context, index) => _tile(width, index),
      );

  Widget _stripView(double width, ComicPageLayout layout) => ListView.builder(
    key: const ValueKey('comic-reader-pages'),
    controller: scrollController,
    padding: EdgeInsets.zero,
    addAutomaticKeepAlives: false,
    itemCount: images.length,
    itemExtentBuilder: (index, _) =>
        index < layout.pageCount ? layout.heightAt(index) : null,
    itemBuilder: (context, index) => _tile(width, index),
  );

  Widget _tile(double width, int index) => Center(
    child: SizedBox(
      width: width,
      child: ComicImageTile(
        key: ValueKey('comic-image-$generation-$index'),
        image: images[index],
        pageNumber: index + 1,
        providerFactory: providerFactory,
        onReady: (w, h) => onImageReady(index, w, h),
        onFailure: () => onImageFailed(index),
        onTap: () => onOpenImage(index),
      ),
    ),
  );
}
