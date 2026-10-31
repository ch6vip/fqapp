import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/reader/eink_image_provider.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets('EinkImageProvider 解出灰度抖动图且不报错', (tester) async {
    // 2x2 彩色图：红、绿、蓝、白。
    final image = img.Image(width: 2, height: 2);
    image.setPixelRgb(0, 0, 255, 0, 0);
    image.setPixelRgb(1, 0, 0, 255, 0);
    image.setPixelRgb(0, 1, 0, 0, 255);
    image.setPixelRgb(1, 1, 255, 255, 255);
    final bytes = img.encodePng(image);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Image(image: EinkImageProvider(MemoryImage(bytes))),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('EinkImageProvider releases the inner listener clone', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final pixels = Uint8List.fromList(const [
        255, 0, 0, 255, //
        0, 255, 0, 255, //
        0, 0, 255, 255, //
        255, 255, 255, 255, //
      ]);
      final decoded = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        2,
        2,
        ui.PixelFormat.rgba8888,
        decoded.complete,
      );
      final source = await decoded.future;

      final inner = _TrackingImageProvider(source);
      final provider = EinkImageProvider(inner);
      final key = await provider.obtainKey(ImageConfiguration.empty);
      final completer = provider.loadImage(
        key,
        (buffer, {getTargetSize}) =>
            Future<ui.Codec>.error(UnimplementedError('decode unused')),
      );
      final result = Completer<ImageInfo>();
      final listener = ImageStreamListener(
        (info, _) {
          if (!result.isCompleted) result.complete(info);
        },
        onError: (Object error, StackTrace? stack) {
          if (!result.isCompleted) {
            result.completeError(error, stack ?? StackTrace.current);
          }
        },
      );
      completer.addListener(listener);
      final output = await result.future;

      // 断言要放在 removeListener 之前：OneFrame completer 在最后一个监听器
      // 移除时会释放它自己的 ImageInfo，而在没有修复时那恰好就是内层
      // completer 交给我们的同一份，会把泄漏掩盖掉。
      expect(inner.delivered, isNotNull);
      // 监听器拿到的是一份 clone；换成处理后的新图后必须由 provider 释放，
      // 否则每张墨水屏插图都会多留一份原图。
      expect(inner.delivered!.image.debugDisposed, isTrue);
      // 原图与交给渲染的新图仍然可用。
      expect(source.debugDisposed, isFalse);
      expect(output.image.debugDisposed, isFalse);
      // 处理确实发生了：输出是重新解码的抖动图，不是原图的 clone。
      expect(output.image.isCloneOf(source), isFalse);
      expect(output.image.width, 2);
      expect(output.image.height, 2);

      completer.removeListener(listener);
      output.dispose();
      source.dispose();
    });
  });
}

/// 内层图片源：把一张现成的图立刻交给监听器，并记下交出去的那份 clone。
class _TrackingImageProvider extends ImageProvider<Object> {
  _TrackingImageProvider(this.image);

  final ui.Image image;
  ImageInfo? delivered;

  @override
  Future<Object> obtainKey(ImageConfiguration configuration) async => this;

  @override
  ImageStreamCompleter loadImage(Object key, ImageDecoderCallback decode) =>
      _ImmediateCompleter(this);
}

class _ImmediateCompleter extends ImageStreamCompleter {
  _ImmediateCompleter(this.owner);

  final _TrackingImageProvider owner;

  @override
  void addListener(ImageStreamListener listener) {
    final info = ImageInfo(image: owner.image.clone(), debugLabel: 'inner');
    owner.delivered = info;
    listener.onImage(info, false);
  }

  @override
  void removeListener(ImageStreamListener listener) {}
}
