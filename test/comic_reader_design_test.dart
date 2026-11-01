import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/comic_reader_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/comic/comic_image_tile.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_sheet.dart';
import 'package:fqapp/widgets/reader/eink_image_provider.dart';

import 'support/fakes.dart';

/// 漫画阅读器的视觉对齐：顶栏 / 底栏 / 目录走项目自有设计语言，
/// 墨水屏下图片灰度化、chrome 与占位纯黑白。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.Image pageImage;

  setUpAll(() async {
    pageImage = await createTestImage(width: 2, height: 2, cache: false);
  });
  tearDownAll(() => pageImage.dispose());
  setUp(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() {
    einkModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
    oledModeNotifier.value = false;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets('墨水屏开关会重新包裹漫画图片并转灰度', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 160,
              child: ComicImageTile(
                image: const ComicImage(url: 'memory://comic-page-1'),
                pageNumber: 1,
                providerFactory: (_) => MemoryImage(_onePixelPng),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    Image tile() => tester.widget<Image>(find.byType(Image));
    expect(tile().image, isA<MemoryImage>());

    einkModeNotifier.value = true;
    await tester.pump();
    expect(tile().image, isA<EinkImageProvider>());

    einkModeNotifier.value = false;
    await tester.pump();
    expect(tile().image, isA<MemoryImage>());
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('墨水屏下漫画 chrome 与占位只用黑白且不转圈', (tester) async {
    einkModeNotifier.value = true;
    final pending = Completer<ui.Image>();
    await tester.pumpWidget(
      _app(
        chapterLoader: (_) async => _images(count: 1),
        provider: (_) => _PendingImageProvider(pending.future),
      ),
    );
    await tester.pump();
    await tester.pump();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, Colors.white);
    final bar = tester.widget<Material>(
      find.byKey(const Key('comic_chapter_bar')),
    );
    expect(bar.color, Colors.white);
    expect(
      tester.widget<Icon>(find.byIcon(LucideIcons.list)).color,
      Colors.black,
    );
    expect(
      tester.widget<Icon>(find.byIcon(LucideIcons.refresh_cw)).color,
      Colors.black,
    );
    expect(
      tester.widget<Text>(find.text('第 1 / 1 页')).style!.color,
      Colors.black,
    );
    // 墨水屏占位：白底、静态图标，不能有持续转动的加载圈。
    final placeholder = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('comic-image-placeholder-1')),
    );
    expect(placeholder.color, Colors.white);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('深色与 OLED 下 chrome 跟随 HomePalette', (tester) async {
    Future<void> expects(ThemeData theme, HomePalette palette) async {
      final pending = Completer<ui.Image>();
      await tester.pumpWidget(
        _app(
          theme: theme,
          chapterLoader: (_) async => _images(count: 1),
          provider: (_) => _PendingImageProvider(pending.future),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        palette.canvas,
      );
      expect(
        tester
            .widget<Material>(find.byKey(const Key('comic_chapter_bar')))
            .color,
        palette.canvas,
      );
      expect(
        tester.widget<Icon>(find.byIcon(LucideIcons.list)).color,
        palette.ink,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }

    const dark = HomePalette(true);
    await expects(AppTheme.createTheme(Brightness.dark), dark);
    themeModeNotifier.value = ThemeMode.dark;
    oledModeNotifier.value = true;
    await expects(
      AppTheme.createTheme(Brightness.dark, oledMode: true),
      const HomePalette(true, oled: true),
    );
  });

  testWidgets('目录使用统一 HomeSheetFrame 并标出当前章', (tester) async {
    await tester.pumpWidget(
      _app(
        chapterLoader: (_) async => _images(),
        provider: (_) => _TestImageProvider(Future.value(pageImage)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeSheetFrame), findsOneWidget);
    expect(find.text('目录 · 共 3 章'), findsOneWidget);
    expect(find.byIcon(LucideIcons.check), findsOneWidget);

    await tester.tap(find.text('第三章'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeSheetFrame), findsNothing);
    expect(find.text('第三章'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('墨水屏下目录当前章仍有描边和勾选', (tester) async {
    einkModeNotifier.value = true;
    final pending = Completer<ui.Image>();
    await tester.pumpWidget(
      _app(
        chapterLoader: (_) async => _images(),
        provider: (_) => _PendingImageProvider(pending.future),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();

    final current = tester.widget<Container>(
      find.byKey(const Key('comic-directory-current')),
    );
    final decoration = current.decoration! as BoxDecoration;
    expect(decoration.color, Colors.white);
    final border = decoration.border! as Border;
    expect(border.top.color, Colors.black);
    expect(border.top.width, 1);
    expect(
      tester.widget<Icon>(find.byIcon(LucideIcons.check)).color,
      Colors.black,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final _chapters = [
  Chapter(itemId: 'chapter-1', title: '第一章', volumeName: ''),
  Chapter(itemId: 'chapter-2', title: '第二章', volumeName: ''),
  Chapter(itemId: 'chapter-3', title: '第三章', volumeName: ''),
];

List<ComicImage> _images({int count = 6}) => List.generate(
  count,
  (index) => ComicImage(url: 'memory://comic/$index', width: 100, height: 200),
);

Widget _app({
  required ComicChapterLoader chapterLoader,
  required ComicImageProviderFactory provider,
  ThemeData? theme,
}) => MaterialApp(
  theme:
      theme ??
      AppTheme.createTheme(Brightness.light, einkMode: einkModeNotifier.value),
  home: ComicReaderPage(
    bookId: 'comic-design',
    title: '漫画',
    chapters: _chapters,
    startIndex: 0,
    readerStore: MemoryReaderStore(),
    // 目录缓存走内存实现：默认 ChapterCacheStore 会打开 Hive，测试结束时
    // 留下它还等在安全存储上的超时计时器。
    cache: MemoryChapterCache(),
    chapterLoader: chapterLoader,
    imageProviderFactory: provider,
  ),
);

class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  final Future<ui.Image> future;
  _TestImageProvider(this.future);

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _TestImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    future.then((image) => ImageInfo(image: image.clone())),
  );
}

class _PendingImageProvider extends ImageProvider<_PendingImageProvider> {
  final Future<ui.Image> future;
  _PendingImageProvider(this.future);

  @override
  Future<_PendingImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _PendingImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    future.then((image) => ImageInfo(image: image.clone())),
  );
}

/// A valid 1x1 transparent PNG.
final _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
