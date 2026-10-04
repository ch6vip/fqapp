import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/chapter_text_formatter.dart';

typedef ReaderImageProviderFactory =
    ImageProvider<Object> Function(ChapterImage image);

class ReaderIllustration extends StatefulWidget {
  final ChapterImage image;
  final ReaderImageProviderFactory? providerFactory;
  final bool allowFullscreen;

  const ReaderIllustration({
    super.key,
    required this.image,
    this.providerFactory,
    this.allowFullscreen = true,
  });

  @override
  State<ReaderIllustration> createState() => _ReaderIllustrationState();
}

class _ReaderIllustrationState extends State<ReaderIllustration> {
  late ImageProvider<Object> _provider = _createProvider();
  int _attempt = 0;
  bool _retrying = false;

  ImageProvider<Object> _createProvider() =>
      widget.providerFactory?.call(widget.image) ??
      CachedNetworkImageProvider(
        widget.image.url,
        maxWidth: 2048,
        maxHeight: 4096,
      );

  @override
  void didUpdateWidget(covariant ReaderIllustration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.url != widget.image.url ||
        oldWidget.providerFactory != widget.providerFactory) {
      _provider = _createProvider();
      ++_attempt;
    }
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      if (widget.providerFactory == null) {
        await CachedNetworkImage.evictFromCache(widget.image.url);
      }
      await _provider.evict();
    } catch (_) {
      // An unavailable cache must not prevent a fresh network attempt.
    }
    if (!mounted) return;
    setState(() {
      _provider = _createProvider();
      ++_attempt;
      _retrying = false;
    });
  }

  void _open() {
    final navigator = Navigator.of(context);
    final image = widget.image;
    final factory = widget.providerFactory;
    navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('插图'),
            leading: IconButton(
              tooltip: '关闭插图',
              onPressed: () => navigator.pop(),
              icon: const Icon(LucideIcons.x),
            ),
          ),
          body: SafeArea(
            child: InteractiveViewer(
              key: const ValueKey('reader-illustration-viewer'),
              minScale: 1,
              maxScale: 5,
              child: SizedBox.expand(
                child: ReaderIllustration(
                  image: image,
                  providerFactory: factory,
                  allowFullscreen: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    button: widget.allowFullscreen,
    label: widget.image.alt.isEmpty ? '小说插图' : widget.image.alt,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.allowFullscreen ? _open : null,
      child: Image(
        key: ValueKey(_attempt),
        image: _provider,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        excludeFromSemantics: true,
        frameBuilder: (context, child, frame, synchronous) =>
            frame == null ? _message(context, failed: false) : child,
        errorBuilder: (context, error, stack) =>
            _message(context, failed: true),
      ),
    ),
  );

  Widget _message(BuildContext context, {required bool failed}) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(failed ? LucideIcons.image_off : LucideIcons.image),
              const SizedBox(height: 8),
              Text(failed ? '插图加载失败' : '正在加载插图'),
              if (failed)
                TextButton.icon(
                  onPressed: _retrying ? null : _retry,
                  icon: const Icon(LucideIcons.rotate_ccw, size: 16),
                  label: Text(_retrying ? '正在重试' : '重试插图'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
