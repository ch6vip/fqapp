import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/widgets/reader/reader_illustration.dart';

void main() {
  late ui.Image image;
  setUpAll(() async {
    image = await createTestImage(width: 4, height: 4);
  });
  tearDownAll(() => image.dispose());

  testWidgets('a stalled image request switches to timeout + retry', (
    tester,
  ) async {
    final provider = _HangingImageProvider();
    await tester.pumpWidget(_app(provider));

    expect(find.text('正在加载插图'), findsOneWidget);

    await tester.pump(const Duration(seconds: 21));
    await tester.pump();

    expect(find.text('插图加载超时'), findsOneWidget);
    expect(find.text('重试插图'), findsOneWidget);

    await tester.tap(find.text('重试插图'));
    await tester.pump();
    expect(find.text('正在加载插图'), findsOneWidget);

    await tester.pump(const Duration(seconds: 21));
    await tester.pump();
    expect(find.text('插图加载超时'), findsOneWidget);
  });

  testWidgets('a frame that arrives before the deadline cancels the timeout', (
    tester,
  ) async {
    final provider = _DelayedImageProvider(
      Future<ui.Image>.delayed(const Duration(seconds: 5), () => image),
    );
    await tester.pumpWidget(_app(provider));

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('正在加载插图'), findsNothing);

    await tester.pump(const Duration(seconds: 21));
    expect(find.text('插图加载超时'), findsNothing);
  });

  testWidgets('disposing before the deadline leaves no pending timer', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_HangingImageProvider()));
    expect(find.text('正在加载插图'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('插图加载超时'), findsNothing);
  });
}

Widget _app(ImageProvider<Object> provider) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 120,
      height: 160,
      child: ReaderIllustration(
        image: const ChapterImage(url: 'https://example.test/p.jpg', alt: ''),
        providerFactory: (_) => provider,
        allowFullscreen: false,
      ),
    ),
  ),
);

class _HangingImageProvider extends ImageProvider<_HangingImageProvider> {
  final Completer<ImageInfo> _never = Completer<ImageInfo>();

  @override
  Future<_HangingImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _HangingImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_never.future);
}

class _DelayedImageProvider extends ImageProvider<_DelayedImageProvider> {
  _DelayedImageProvider(this._future);

  final Future<ui.Image> _future;

  @override
  Future<_DelayedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _DelayedImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    _future.then((image) => ImageInfo(image: image)),
  );
}
