import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'eink_reading.dart';

/// 墨水屏图片包装器：把任意 [ImageProvider] 解出的图转灰度 + 抖动后显示。
///
/// 只在墨水屏模式下由 ReaderIllustration 包一层；普通模式走原 provider，
/// 缓存 key 不同，开关墨水屏不会互相串图。
/// 处理失败时退回原图，不让一张插图拖垮整页。
/// 超大图（像素数超过 2048×4096）跳过处理，避免一次拷几十 MB 内存。
class EinkImageProvider extends ImageProvider<EinkImageKey> {
  final ImageProvider<Object> inner;

  const EinkImageProvider(this.inner);

  @override
  Future<EinkImageKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(EinkImageKey(inner, configuration));

  @override
  ImageStreamCompleter loadImage(
    EinkImageKey key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(_load(key, decode));
  }

  Future<ImageInfo> _load(
    EinkImageKey key,
    ImageDecoderCallback decode,
  ) async {
    final innerKey = await key.inner.obtainKey(key.configuration);
    final completer = key.inner.loadImage(innerKey, decode);
    final info = await _firstImage(completer);
    try {
      final processed = await _process(info.image);
      return ImageInfo(
        image: processed,
        scale: info.scale,
        debugLabel: 'EinkImageProvider(${info.debugLabel})',
      );
    } catch (_) {
      // 处理失败退回原图：插图是装饰，绝不能因此报错。
      return info;
    }
  }

  Future<ImageInfo> _firstImage(ImageStreamCompleter completer) {
    final result = Completer<ImageInfo>();
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!result.isCompleted) result.complete(info);
        completer.removeListener(listener);
      },
      onError: (Object error, StackTrace? stack) {
        if (!result.isCompleted) result.completeError(error, stack);
        completer.removeListener(listener);
      },
    );
    completer.addListener(listener);
    return result.future;
  }

  Future<ui.Image> _process(ui.Image image) async {
    if (image.width * image.height > 2048 * 4096) return image;
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) return image;
    final rgba = bytes.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    final processed = await Isolate.run(
      () => einkDitherPixels(rgba, image.width, image.height),
    );
    final result = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      processed,
      image.width,
      image.height,
      ui.PixelFormat.rgba8888,
      result.complete,
    );
    return result.future;
  }
}

class EinkImageKey {
  final ImageProvider<Object> inner;
  final ImageConfiguration configuration;

  const EinkImageKey(this.inner, this.configuration);

  @override
  bool operator ==(Object other) =>
      other is EinkImageKey &&
      other.inner == inner &&
      other.configuration == configuration;

  @override
  int get hashCode => Object.hash(EinkImageKey, inner, configuration);
}
