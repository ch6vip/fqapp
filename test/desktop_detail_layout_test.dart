import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/widgets/desktop_app_frame.dart';
import 'package:fqapp/widgets/detail/detail_read_bar.dart';
import 'support/fakes.dart';

const _capture = bool.fromEnvironment('FQAPP_CAPTURE_LAYOUT');
const _boundary = Key('desktop-detail-capture');

void _testWindows(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_capture) {
      final fonts =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final family in fonts) {
        final loader = FontLoader(family['family'] as String);
        for (final font in family['fonts'] as List) {
          loader.addFont(rootBundle.load(font['asset'] as String));
        }
        await loader.load();
      }
      final file = File(r'C:\Windows\Fonts\msyh.ttc');
      if (file.existsSync()) {
        await (FontLoader(
          'DesktopQA',
        )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DesktopPlatform.fullscreen.value = false;
    desktopTab.value = 0;
  });

  for (final sample
      in <({double width, double height, double scale, String layout})>[
        (width: 600, height: 768, scale: 1, layout: 'mobile'),
        (width: 700, height: 768, scale: 1, layout: 'compact'),
        (width: 999, height: 768, scale: 1, layout: 'compact'),
        (width: 1000, height: 768, scale: 1, layout: 'two'),
        (width: 1399, height: 768, scale: 1, layout: 'two'),
        (width: 1400, height: 768, scale: 1, layout: 'three'),
        (width: 1366, height: 768, scale: 1, layout: 'two'),
        (width: 1920, height: 1080, scale: 1, layout: 'three'),
        // 1366x768 and 1920x1080 physical screens at 150% Windows DPI.
        (width: 910, height: 512, scale: 1, layout: 'compact'),
        (width: 1280, height: 720, scale: 1, layout: 'two'),
        (width: 1366, height: 768, scale: 1.5, layout: 'two'),
      ]) {
    _testWindows(
      'Windows detail ${sample.width}x${sample.height} text ${sample.scale}',
      (tester) async {
        await _pump(
          tester,
          Size(sample.width, sample.height),
          scale: sample.scale,
        );
        expect(tester.takeException(), isNull);
        if (sample.layout == 'mobile') {
          expect(find.byType(DetailReadBar), findsOneWidget);
        } else {
          expect(find.byType(AppBar), findsNothing);
          expect(find.byType(DetailReadBar), findsNothing);
          expect(
            find.byKey(Key('desktop-detail-${sample.layout}')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('detail_read_button_desktop')),
            findsOneWidget,
          );
          expect(
            tester
                .getSize(find.byKey(const Key('detail_read_button_desktop')))
                .height,
            greaterThanOrEqualTo(44),
          );
          expect(find.byKey(const Key('detail_id_copy')), findsOneWidget);
          expect(
            tester.widget<NavigationRail>(find.byType(NavigationRail)).minWidth,
            76,
          );
          expect(find.byKey(const Key('desktop-settings')), findsOneWidget);
        }
        if (_capture && sample.width >= 700) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(_boundary),
            );
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/validation/desktop-detail/${sample.width.toInt()}-${sample.scale}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  _testWindows('desktop tabs search all chapters and open the original index', (
    tester,
  ) async {
    final observer = _Observer();
    await _pump(tester, const Size(1366, 768), observer: observer);
    expect(find.byKey(const Key('detail_description_text')), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsNWidgets(4));
    expect(find.byIcon(Icons.star_half_rounded), findsOneWidget);
    await tester.tap(find.byKey(const Key('detail_section_2')));
    await tester.pumpAndSettle();
    expect(find.text('还没有读者评论'), findsOneWidget);
    await tester.tap(find.byKey(const Key('detail_section_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('detail_description_text')), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, '搜索目录'), '第 205 章');
    await tester.pumpAndSettle();
    expect(find.text('第 205 章 故事继续'), findsOneWidget);
    final context = tester.element(find.byType(DetailPage));
    await tester.tap(find.text('第 205 章 故事继续'));
    await tester.idle();
    final page =
        (observer.route! as MaterialPageRoute).builder(context) as ReaderPage;
    expect(page.startIndex, 204);
    expect(page.shelfItem?.id, _book.id);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _pump(
  WidgetTester tester,
  Size size, {
  double scale = 1,
  NavigatorObserver? observer,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        navigatorKey: DesktopPlatform.navigatorKey,
        navigatorObservers: [?observer],
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xfff65a38),
          fontFamily: _capture ? 'DesktopQA' : null,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: DesktopAppFrame(child: child!),
        ),
        home: DetailPage(
          item: _book,
          readerStore: MemoryReaderStore(),
          chapterCache: MemoryChapterCache(),
          detailLoader: (id, {String tab = '小说'}) async => {
            'data': {
              'book_name': _book.title,
              'abstract':
                  '少年踏上旅途，在山川与星河之间寻找新的故事。每一次相遇都带来不同的选择，也让平凡的日常有了温暖的光。' * 3,
              'score': '9.5',
              'read_count': '246000',
              'word_number': '1280000',
              'tags': '奇幻,冒险',
              'author_info': {'user_name': '测试作者', 'user_id': 'author'},
            },
          },
          directoryLoader: (id, {String tab = '小说'}) async => [
            List.generate(
              240,
              (i) => Chapter(
                itemId: 'chapter-$i',
                title: '第 ${i + 1} 章 故事继续',
                volumeName: '第一卷',
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _book = MediaItem(
  id: 'desktop-detail-book',
  title: '山川与星河：一段新的旅程',
  cover: '',
  author: '测试作者',
  badge: '',
  ep: '',
  kind: 'book',
);

class _Observer extends NavigatorObserver {
  Route<dynamic>? route;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    this.route = route;
  }
}
