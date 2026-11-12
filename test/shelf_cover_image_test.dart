import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/poster_cache.dart';
import 'package:fqapp/widgets/home/home_archive.dart' show einkCoverFilter;
import 'package:fqapp/widgets/shelf/shelf_cover_image.dart';

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

MediaItem _item({String cover = '', String title = '封面书'}) => MediaItem(
  id: '1',
  title: title,
  cover: cover,
  author: '作者',
  badge: '',
  ep: '',
  kind: 'book',
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 200, height: 280, child: child)),
  ),
);

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  late Directory temp;

  setUp(() {
    einkModeNotifier.value = false;
    temp = Directory.systemTemp.createTempSync('fqapp_shelf_cover_test');
    // `PosterCache` is backed by `flutter_cache_manager`, which asks
    // path_provider for its directory. Give the widget tests a real scratch
    // directory instead of leaving the plugin missing.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
          return temp.path;
        });
  });

  tearDown(() {
    einkModeNotifier.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('isRemoteCover 只认 http(s)', () {
    expect(isRemoteCover('https://a/b.jpg'), isTrue);
    expect(isRemoteCover('HTTP://a/b.jpg'), isTrue);
    expect(isRemoteCover('file:///a/b.png'), isFalse);
    expect(isRemoteCover('/a/b.png'), isFalse);
  });

  test('shelfCoverDecodeWidth 按像素比计算并封顶', () {
    expect(shelfCoverDecodeWidth(100, 2), 200);
    expect(shelfCoverDecodeWidth(100, 2.5), 250);
    expect(shelfCoverDecodeWidth(0, 1), 1);
    expect(shelfCoverDecodeWidth(4000, 3), 1536);
  });

  test('远程封面预热与显示共用 PosterCache 和同一个磁盘键', () {
    final provider = shelfCoverImageProvider('https://img/cover.jpg', 120, 2);
    expect(provider, isA<ResizeImage>());
    final resize = provider as ResizeImage;
    // 解码宽度只影响内存缓存；磁盘键必须和显示侧的 CachedNetworkImage 一致，
    // 否则预热写进去的文件在显示时会被当成另一条记录再下一遍。
    expect(resize.width, 240);
    expect(resize.height, isNull);
    final inner = resize.imageProvider;
    expect(inner, isA<CachedNetworkImageProvider>());
    final cached = inner as CachedNetworkImageProvider;
    expect(cached.url, 'https://img/cover.jpg');
    expect(cached.maxWidth, isNull);
    expect(identical(cached.cacheManager, PosterCache.instance), isTrue);
  });

  test('本地位图使用 ResizeImage + FileImage', () {
    final file = File('${temp.path}/cover.png')
      ..writeAsBytesSync(base64Decode(_onePixelPng));
    final provider = shelfCoverImageProvider(file.path, 120, 2);
    expect(provider, isA<ResizeImage>());
    final resize = provider as ResizeImage;
    expect(resize.width, 240);
    expect(resize.imageProvider, isA<FileImage>());
    expect((resize.imageProvider as FileImage).file.path, file.path);
  });

  test('空封面或 SVG 不提供 ImageProvider', () {
    expect(() => shelfCoverImageProvider('', 100, 1), throwsArgumentError);
    expect(
      () => shelfCoverImageProvider('/tmp/cover.svg', 100, 1),
      throwsArgumentError,
    );
  });

  testWidgets('空封面回落默认 fallback', (tester) async {
    await tester.pumpWidget(
      _host(ShelfCoverImage(item: _item(), width: 120, height: 160)),
    );
    expect(find.byType(ShelfCoverFallback), findsOneWidget);
    expect(find.byKey(ShelfCoverFallback.coverKey), findsOneWidget);
    expect(find.text('封面书'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fallback 对齐上游 NovelCover：平色 #202020 与 3dp 圆角', (tester) async {
    await tester.pumpWidget(
      _host(ShelfCoverFallback(item: _item(), width: 120, height: 160)),
    );
    final box = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(ShelfCoverFallback),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(box.color, const Color(0xFF202020));
    final clip = tester.widget<ClipRRect>(
      find.descendant(
        of: find.byType(ShelfCoverFallback),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(clip.borderRadius, BorderRadius.circular(3));
    final padding = tester.widget<Padding>(
      find.descendant(
        of: find.byType(ShelfCoverFallback),
        matching: find.byType(Padding),
      ),
    );
    expect(padding.padding, const EdgeInsets.all(120 * .11));
    final title = tester.widget<Text>(find.text('封面书'));
    expect(title.style?.fontSize, 120 * .16);
    expect(title.style?.color, Colors.white);
    final author = tester.widget<Text>(find.text('作者'));
    expect(author.style?.fontSize, 120 * .085);
  });

  testWidgets('远程封面：PosterCache、memCacheWidth、placeholder/error 回调', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final item = _item(cover: 'https://img/cover.jpg');
    await tester.pumpWidget(
      _host(ShelfCoverImage(item: item, width: 120, height: 160)),
    );
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(identical(image.cacheManager, PosterCache.instance), isTrue);
    expect(image.memCacheWidth, shelfCoverDecodeWidth(120, 1));
    final context = tester.element(find.byType(CachedNetworkImage));
    expect(
      image.placeholder!(context, image.imageUrl),
      isA<ShelfCoverFallback>(),
    );
    expect(
      image.errorWidget!(context, image.imageUrl, Object()),
      isA<ShelfCoverFallback>(),
    );
  });

  testWidgets('调用方 fallback 同时用于占位与错误', (tester) async {
    const fallback = Text('自定义兜底');
    await tester.pumpWidget(
      _host(
        ShelfCoverImage(
          item: _item(cover: 'https://img/cover.jpg'),
          width: 120,
          height: 160,
          fallback: fallback,
        ),
      ),
    );
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    final context = tester.element(find.byType(CachedNetworkImage));
    expect(image.placeholder!(context, image.imageUrl), same(fallback));
    expect(
      image.errorWidget!(context, image.imageUrl, Object()),
      same(fallback),
    );
  });

  testWidgets('本地 SVG 走 SvgPicture', (tester) async {
    final file = File('${temp.path}/cover.svg')
      ..writeAsStringSync(
        '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
        '<rect width="10" height="10" fill="#000"/></svg>',
      );
    await tester.pumpWidget(
      _host(
        ShelfCoverImage(
          item: _item(cover: file.path),
          width: 120,
          height: 160,
          fit: BoxFit.contain,
        ),
      ),
    );
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.fit, BoxFit.contain);
  });

  testWidgets('本地位图走 Image.file 并带 cacheWidth', (tester) async {
    final file = File('${temp.path}/cover.png')
      ..writeAsBytesSync(base64Decode(_onePixelPng));
    await tester.pumpWidget(
      _host(
        ShelfCoverImage(
          item: _item(cover: file.path),
          width: 120,
          height: 160,
          decodeWidth: 360,
        ),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
    final resize = image.image as ResizeImage;
    expect(resize.width, 360);
    expect(resize.imageProvider, isA<FileImage>());
    expect(image.width, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('墨水屏启用灰度滤镜', (tester) async {
    einkModeNotifier.value = true;
    await tester.pumpWidget(
      _host(ShelfCoverImage(item: _item(), width: 120, height: 160)),
    );
    final filtered = tester.widgetList<ColorFiltered>(
      find.byType(ColorFiltered),
    );
    expect(
      filtered.any((widget) => widget.colorFilter == einkCoverFilter),
      isTrue,
    );
  });

  testWidgets('radius 包裹 ClipRRect', (tester) async {
    await tester.pumpWidget(
      _host(
        ShelfCoverImage(item: _item(), width: 120, height: 160, radius: 10),
      ),
    );
    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
    expect(clip.borderRadius, BorderRadius.circular(10));
  });

  testWidgets('precacheShelfCover 对本地封面立即返回', (tester) async {
    await tester.pumpWidget(
      _host(ShelfCoverImage(item: _item(), width: 120, height: 160)),
    );
    final context = tester.element(find.byType(ShelfCoverImage));
    await precacheShelfCover(context, '/tmp/cover.png', 120);
    await precacheShelfCover(context, '', 120);
  });
}
