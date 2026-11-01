import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/chapter_media.dart';
import '../../services/app_theme.dart';
import '../home/home_design.dart';
import '../reader/eink_image_provider.dart';

/// Default provider for one comic page: memory-only.
///
/// Comic URLs carry the per-launch loopback capability in their path, so
/// they must never go through a disk-persisted image cache: a cached entry
/// would keep the capability alive past the launch that issued it.
/// [NetworkImage] only feeds Flutter's in-memory [ImageCache], and
/// [ResizeImage] with [ResizeImagePolicy.fit] keeps the old 2048×8192
/// decode bound as an aspect-preserving max box (the old
/// `CachedNetworkImageProvider` maxWidth/maxHeight semantics; the
/// `exact` default would stretch to 2048×8192).
@visibleForTesting
ImageProvider<Object> defaultComicImageProvider(ComicImage image) =>
    ResizeImage(
      NetworkImage(
        image.url,
        headers: image.headers.isEmpty ? null : image.headers,
      ),
      width: 2048,
      height: 8192,
      policy: ResizeImagePolicy.fit,
    );

/// One comic page with loading / error placeholders in the home palette.
///
/// 墨水屏下图片会在 [ImageProvider] 外面再包一层 [EinkImageProvider]（灰度
/// + 抖动），与阅读器插图同一套处理；占位与 chrome 走 [HomePalette]，墨水屏
/// 自动退化成纯黑白。
class ComicImageTile extends StatefulWidget {
  final ComicImage image;
  final int pageNumber;
  final ImageProvider<Object> Function(ComicImage image)? providerFactory;
  final void Function(int width, int height)? onReady;
  final VoidCallback? onFailure;
  final VoidCallback? onTap;

  const ComicImageTile({
    super.key,
    required this.image,
    required this.pageNumber,
    this.providerFactory,
    this.onReady,
    this.onFailure,
    this.onTap,
  });

  @override
  State<ComicImageTile> createState() => _ComicImageTileState();
}

class _ComicImageTileState extends State<ComicImageTile> {
  ImageProvider<Object>? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  int _attempt = 0;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    einkModeNotifier.addListener(_onEinkChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_provider == null) _resolve();
  }

  @override
  void didUpdateWidget(covariant ComicImageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.url != widget.image.url ||
        oldWidget.providerFactory != widget.providerFactory) {
      _resolve();
    }
  }

  void _onEinkChanged() {
    if (!mounted) return;
    setState(() {
      _resolve();
      ++_attempt;
    });
  }

  ImageProvider<Object> _createProvider() {
    final base =
        widget.providerFactory?.call(widget.image) ??
        defaultComicImageProvider(widget.image);
    // 墨水屏：先转灰度抖动再交给屏幕，避免面板自己量化出彩色噪点。
    return einkModeNotifier.value ? EinkImageProvider(base) : base;
  }

  void _resolve() {
    _removeListener();
    _provider = _createProvider();
    final attempt = _attempt;
    var reported = false;
    _listener = ImageStreamListener(
      (info, synchronous) {
        final width = info.image.width;
        final height = info.image.height;
        info.dispose(); // This listener owns its ImageInfo clone, not Image's.
        if (reported) return;
        reported = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && attempt == _attempt) {
            widget.onReady?.call(width, height);
          }
        });
      },
      onError: (Object error, StackTrace? stack) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && attempt == _attempt) widget.onFailure?.call();
        });
      },
    );
    _stream = _provider!.resolve(createLocalImageConfiguration(context));
    _stream!.addListener(_listener!);
  }

  void _removeListener() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      // 内存图片缓存没有落盘层：只清内存缓存就足以强制重新拉取。
      await _provider?.evict();
    } catch (_) {
      // A cache cleanup failure should not suppress an explicit network retry.
    }
    if (!mounted) return;
    setState(() {
      ++_attempt;
      _retrying = false;
      _resolve();
    });
  }

  @override
  void dispose() {
    einkModeNotifier.removeListener(_onEinkChanged);
    _removeListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Semantics(
      label: '第 ${widget.pageNumber} 页漫画',
      button: widget.onTap != null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Image(
          key: ValueKey(_attempt),
          image: _provider!,
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: false,
          frameBuilder: (context, child, frame, synchronous) =>
              frame != null ? child : _loadingPlaceholder(palette),
          errorBuilder: (context, error, stack) => _errorPlaceholder(palette),
        ),
      ),
    );
  }

  Widget _loadingPlaceholder(HomePalette palette) => ColoredBox(
    key: ValueKey('comic-image-placeholder-${widget.pageNumber}'),
    color: palette.soft,
    child: Center(
      child: SingleChildScrollView(
        primary: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 墨水屏：转圈动画会留残影，换成一个静态占位图标。
            if (palette.eink)
              Icon(LucideIcons.image, size: 24, color: palette.muted)
            else
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: palette.ink,
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '正在加载第 ${widget.pageNumber} 页',
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _errorPlaceholder(HomePalette palette) => ColoredBox(
    key: ValueKey('comic-image-error-${widget.pageNumber}'),
    color: palette.soft,
    child: Center(
      child: SingleChildScrollView(
        primary: false,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.image_off, size: 24, color: palette.muted),
              const SizedBox(height: 8),
              Text(
                '第 ${widget.pageNumber} 页加载失败',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.ink),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _retrying ? null : _retry,
                style: TextButton.styleFrom(
                  foregroundColor: palette.accentText,
                ),
                icon: const Icon(LucideIcons.refresh_cw, size: 16),
                label: Text(_retrying ? '正在重试' : '重试图片'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
