import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets(
    'menu animation preserves the viewport, paragraph and saved position',
    (tester) async {
      await _size(tester, const Size(390, 800));
      final store = MemoryReaderStore();
      await tester.pumpWidget(_app(_reader(store: store)));
      await tester.pumpAndSettle();
      final controller = _controller(tester);
      controller.jumpTo(450);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      final viewport = tester.getRect(_surface);
      final paragraph = _firstVisibleParagraph(tester);
      final paragraphRect = tester.getRect(find.byKey(paragraph));
      for (var i = 0; i < 4; i++) {
        await tester.tapAt(viewport.center);
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.getRect(_surface), viewport);
        expect(controller.offset, 450);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byKey(paragraph)), paragraphRect);
        expect(store.entry?['position'], 450);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('back first closes the menu and then leaves the reader', (
    tester,
  ) async {
    final device = _Device();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _reader(device: device),
                ),
              ),
              child: const Text('打开阅读'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开阅读'));
    await tester.pumpAndSettle();
    await _openMenu(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-controls')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPage), findsNothing);
    expect(device.calls.last, 'close');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('clock and battery update while the menu is hidden', (
    tester,
  ) async {
    final device = _Device();
    await tester.pumpWidget(_app(_reader(device: device)));
    await tester.pumpAndSettle();
    expect(find.text('21:16'), findsOneWidget);
    expect(find.text('64%'), findsOneWidget);
    device.events.add(
      ReaderDeviceStatus(time: DateTime(2026, 9, 10, 21, 17), battery: 63),
    );
    await tester.pump();
    expect(find.text('21:17'), findsOneWidget);
    expect(find.text('63%'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-controls')), findsNothing);
    final oldProgress = tester
        .widget<Text>(find.byKey(const ValueKey('reader-progress')))
        .data;
    _controller(tester).jumpTo(350);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('reader-progress'))).data,
      isNot(oldProgress),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('brightness follows the user choice and reader lifecycle', (
    tester,
  ) async {
    final device = _Device();
    await tester.pumpWidget(_app(_reader(device: device)));
    await tester.pumpAndSettle();
    expect(device.calls, contains('start:true:0.5'));
    await _openMenu(tester);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('reader-brightness')),
    );
    slider.onChanged!(0.3);
    slider.onChangeEnd!(0.3);
    await tester.pumpAndSettle();
    expect(device.calls, contains('brightness:false:0.3'));
    expect((await ReaderPreferences.load()).followSystemBrightness, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(device.calls.last, 'suspend');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(device.calls.last, 'start:false:0.3');
    await tester.tap(find.byKey(const ValueKey('reader-follow-system')));
    await tester.pumpAndSettle();
    expect(device.calls.last, 'brightness:true:0.3');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(device.calls.last, 'close');
    expect((await ReaderPreferences.load()).followSystemBrightness, isTrue);
  });

  testWidgets(
    'appearance edits keep the current paragraph and persist new settings',
    (tester) async {
      await _size(tester, const Size(390, 800));
      await tester.pumpWidget(_app(_reader()));
      await tester.pumpAndSettle();
      _controller(tester).jumpTo(510);
      await tester.pumpAndSettle();
      final anchor = _firstVisibleParagraph(tester);
      await _openAppearance(tester);
      await tester.tap(find.byTooltip('增大字号'));
      await tester.pumpAndSettle();
      expect(_firstVisibleParagraph(tester), anchor);
      await tester.tap(find.byTooltip('增大字距'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('reader-more-appearance')),
      );
      await tester.tap(find.text('标题与留白'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('标题居中'));
      await tester.tap(find.text('标题居中'));
      await tester.ensureVisible(find.byTooltip('增大上下留白'));
      await tester.tap(find.byTooltip('增大上下留白'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭排版设置'));
      await tester.pumpAndSettle();
      final preferences = await ReaderPreferences.load();
      expect(preferences.fontSize, 19);
      expect(preferences.letterSpacing, closeTo(0.1, 0.001));
      expect(preferences.titleAlignment, ReaderTitleAlignment.center);
      expect(preferences.verticalPadding, 17);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'night directory uses the reader palette instead of the app day theme',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader_theme_preset': 'dark',
        'reader_page_mode': 'scroll',
      });
      await tester.pumpWidget(_app(_reader()));
      await tester.pumpAndSettle();
      await _openMenu(tester);
      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      final directory = find.text('目录 · 2 章');
      expect(
        Theme.of(tester.element(directory)).colorScheme.brightness,
        Brightness.dark,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text('第二章 远山'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-controls')), findsNothing);
      expect(find.text('第二章 远山'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a cancelled font import keeps the existing appearance', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_reader()));
    await tester.pumpAndSettle();
    await _openAppearance(tester);
    await tester.ensureVisible(find.text('导入字体'));
    await tester.tap(find.text('导入字体'));
    await tester.pumpAndSettle();
    expect(find.text('系统字体'), findsOneWidget);
    expect(find.textContaining('无法载入字体'), findsNothing);
    await tester.tap(find.byTooltip('关闭排版设置'));
    await tester.pumpAndSettle();
    expect((await ReaderPreferences.load()).fontPath, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final layout in [
    (name: 'portrait', size: const Size(390, 844), scale: 1.0),
    (name: 'narrow large text', size: const Size(280, 600), scale: 2.0),
    (name: 'landscape', size: const Size(780, 360), scale: 1.4),
  ]) {
    testWidgets('reader panels fit ${layout.name}', (tester) async {
      final previousShadows = debugDisableShadows;
      try {
        await _size(tester, layout.size);
        if (layout.name == 'portrait') await _loadPreviewFont(tester);
        await tester.pumpWidget(_app(_reader(), scale: layout.scale));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (layout.name == 'portrait') await _capture(tester, 'reading');
        await _openMenu(tester);
        expect(tester.takeException(), isNull);
        if (layout.name == 'portrait') await _capture(tester, 'menu');
        await tester.ensureVisible(find.text('排版'));
        await tester.tap(find.text('排版'));
        await tester.pumpAndSettle();
        expect(find.text('排版设置'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (layout.name == 'portrait') await _capture(tester, 'appearance');
        await tester.tap(find.byKey(const ValueKey('reader-theme-dark')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('关闭排版设置'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (layout.name == 'portrait') await _capture(tester, 'night');
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDisableShadows = previousShadows;
      }
    });
  }
}

final _surface = find.byKey(const ValueKey('reader-page-surface'));
final _chapters = [
  Chapter(itemId: 'chapter-1', title: '第一章 山间来信', volumeName: '正文'),
  Chapter(itemId: 'chapter-2', title: '第二章 远山', volumeName: '正文'),
];

ReaderPage _reader({MemoryReaderStore? store, _Device? device}) => ReaderPage(
  bookId: 'interface-test',
  title: '山川来信',
  chapters: _chapters,
  startIndex: 0,
  readerDevice: device ?? _Device(),
  readerStore: store ?? MemoryReaderStore(),
  chapterCache: MemoryChapterCache(),
  chapterLoader: (_) async => List.generate(
    60,
    (index) => _paragraphs[index % _paragraphs.length],
  ).join('\n\n'),
);

const _paragraphs = [
  '清晨的风从窗边吹来，带着山间草木的清香。林舟推开木窗，看见远处的云正慢慢越过山脊。',
  '桌上放着一封尚未拆开的信，纸张微微泛黄，封口处印着一个熟悉的名字。他在窗前坐下，将信小心地展开。',
  '“如果有一天，你再次走到这条路的尽头，请记得停下来，听一听风的声音。”',
  '窗外传来鸟鸣，清亮又遥远。那些被时光掩藏的往事，仿佛随着这句话，重新有了颜色。',
  '他把信收进口袋，带上那本翻过许多遍的旧书。山路就在门外，阳光落在石阶上，一直延伸向远方。',
];

Widget _app(Widget child, {double scale = 1}) => MaterialApp(
  builder: (context, child) => RepaintBoundary(
    key: const ValueKey('reader-preview-boundary'),
    child: MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
  ),
  home: child,
);

Future<void> _size(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

ScrollController _controller(WidgetTester tester) => tester
    .widget<ListView>(find.byKey(const ValueKey('reader-paragraph-list')))
    .controller!;

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tapAt(tester.getRect(_surface).center);
  await tester.pumpAndSettle();
}

Future<void> _openAppearance(WidgetTester tester) async {
  await _openMenu(tester);
  await tester.ensureVisible(find.text('排版'));
  await tester.tap(find.text('排版'));
  await tester.pumpAndSettle();
}

ValueKey<String> _firstVisibleParagraph(WidgetTester tester) {
  final top = tester.getRect(_surface).top;
  for (var i = 0; i < 60; i++) {
    final key = ValueKey('reader-paragraph-$i');
    final finder = find.byKey(key);
    if (finder.evaluate().isEmpty) continue;
    if (tester.getRect(finder).bottom > top) return key;
  }
  throw StateError('No visible paragraph');
}

class _Device extends ReaderDevice {
  final events = StreamController<ReaderDeviceStatus>.broadcast(sync: true);
  final calls = <String>[];
  final status = ReaderDeviceStatus(
    time: DateTime(2026, 9, 10, 21, 16),
    battery: 64,
    systemBrightness: 0.45,
  );

  _Device() {
    addTearDown(events.close);
  }
  @override
  Stream<ReaderDeviceStatus> get changes => events.stream;
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async {
    calls.add('start:$followSystem:$brightness');
    return status;
  }

  @override
  Future<bool> setBrightness({
    required bool followSystem,
    required double brightness,
  }) async {
    calls.add('brightness:$followSystem:$brightness');
    return true;
  }

  @override
  Future<void> suspend() async {
    calls.add('suspend');
  }

  @override
  Future<void> close() async {
    calls.add('close');
  }

  @override
  Future<ReaderFont?> pickFont() async => null;
}

const _previewFont = String.fromEnvironment('READER_PREVIEW_FONT');

Future<void> _loadPreviewFont(WidgetTester tester) async {
  if (_previewFont.isEmpty) return;
  debugDisableShadows = false;
  await tester.runAsync(() async {
    final bytes = await File(_previewFont).readAsBytes();
    final loader = FontLoader('Roboto')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (_previewFont.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('reader-preview-boundary')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/validation/reader-interface-20260910/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
