import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_media_card.dart';
import 'package:fqapp/widgets/home/home_spotlight.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';

void main() {
  testWidgets('swiping and next open the visible recommendation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        HomeSpotlight(
          items: [_item('one'), _item('two'), _item('three')],
          onOpen: (item) => opened.add(item.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('01 / 03'), findsOneWidget);

    await tester.fling(
      find.byKey(const Key('home_spotlight_pages')),
      const Offset(-320, 0),
      600,
    );
    await tester.pumpAndSettle();
    expect(find.text('02 / 03'), findsOneWidget);
    await tester.tap(find.text('故事 two').hitTestable());
    await tester.pumpAndSettle();
    expect(opened, ['two']);

    await tester.tap(find.byKey(const Key('home_spotlight_next')));
    await tester.pumpAndSettle();
    expect(find.text('03 / 03'), findsOneWidget);
    await tester.tap(find.text('故事 three').hitTestable());
    await tester.pumpAndSettle();
    expect(opened, ['two', 'three']);

    await tester.tap(find.byKey(const Key('home_spotlight_next')));
    await tester.pumpAndSettle();
    expect(find.text('01 / 03'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refreshing a shorter set resets to its first story', (
    tester,
  ) async {
    final opened = <String>[];
    Widget content(List<MediaItem> items) => _app(
      HomeSpotlight(items: items, onOpen: (item) => opened.add(item.id)),
    );
    await tester.pumpWidget(
      content([_item('one'), _item('two'), _item('three')]),
    );
    await tester.tap(find.byKey(const Key('home_spotlight_next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home_spotlight_next')));
    await tester.pumpAndSettle();

    await tester.pumpWidget(content([_item('fresh')]));
    await tester.pumpAndSettle();
    expect(find.text('01 / 01'), findsOneWidget);
    expect(find.byKey(const Key('home_spotlight_next')), findsNothing);
    await tester.tap(find.text('故事 fresh'));
    await tester.pumpAndSettle();
    expect(opened, ['fresh']);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (width: 320.0, scale: 1.0, dark: false),
    (width: 320.0, scale: 1.8, dark: true),
    (width: 320.0, scale: 3.0, dark: false),
    (width: 800.0, scale: 1.0, dark: true),
  ]) {
    testWidgets('story content remains readable with $scenario', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(scenario.width, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final item = _item(
        'long',
        title: '一本名字很长但也要保持清晰易读的故事',
        author: '作者名字很长也不会挤出卡片边界',
        ep: '更新至一千零一章',
      );
      await tester.pumpWidget(
        _app(
          SingleChildScrollView(
            child: HomeSpotlight(items: [item, _item('next')], onOpen: (_) {}),
          ),
          scale: scenario.scale,
          dark: scenario.dark,
          reducedMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        _app(
          LayoutBuilder(
            builder: (context, constraints) => GridView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              gridDelegate: homeGridDelegate(
                context,
                constraints.maxWidth - 40,
              ),
              children: List.generate(
                6,
                (_) => HomeMediaCard(item: item, onTap: () {}),
              ),
            ),
          ),
          scale: scenario.scale,
          dark: scenario.dark,
          reducedMotion: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a category can be selected through its semantics action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    int? selected;
    await tester.pumpWidget(
      _app(
        CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              delegate: HomeTabBarDelegate(
                selectedIndex: 0,
                onSelect: (index) => selected = index,
              ),
            ),
          ],
        ),
      ),
    );
    final node = tester.getSemantics(
      find.byKey(const ValueKey('home_category_1')),
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(selected, 1);
    semantics.dispose();
  });

  test('the pinned tab bar rebuilds when brightness changes', () {
    void ignore(int _) {}
    final light = HomeTabBarDelegate(
      selectedIndex: 0,
      onSelect: ignore,
      dark: false,
    );
    final dark = HomeTabBarDelegate(
      selectedIndex: 0,
      onSelect: ignore,
      dark: true,
    );
    expect(dark.shouldRebuild(light), isTrue);
    expect(
      light.shouldRebuild(
        HomeTabBarDelegate(selectedIndex: 0, onSelect: ignore),
      ),
      isFalse,
    );
  });

  testWidgets('the pinned tab bar follows the theme without changing tabs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    void select(int _) {}
    Widget app(Brightness brightness) {
      return MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: HomeTabBarDelegate(
                selectedIndex: 0,
                onSelect: select,
                dark: brightness == Brightness.dark,
              ),
            ),
          ],
        ),
      );
    }

    Color canvasOf() {
      final box = tester
          .widgetList<DecoratedBox>(
            find.ancestor(
              of: find.byKey(const ValueKey('home_category_0')),
              matching: find.byType(DecoratedBox),
            ),
          )
          .first;
      return (box.decoration as BoxDecoration).color!;
    }

    await tester.pumpWidget(app(Brightness.light));
    await tester.pumpAndSettle();
    expect(canvasOf(), const HomePalette(false).canvas);

    await tester.pumpWidget(app(Brightness.dark));
    await tester.pumpAndSettle();
    expect(canvasOf(), const HomePalette(true).canvas);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion leaves press and page changes settled', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            HomePressable(
              onTap: () => taps++,
              child: const SizedBox(width: 100, height: 50, child: Text('打开')),
            ),
            HomeSpotlight(items: [_item('one'), _item('two')], onOpen: (_) {}),
          ],
        ),
        reducedMotion: true,
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    expect(taps, 1);
    await tester.tap(find.byKey(const Key('home_spotlight_next')));
    await tester.pump();
    await tester.pump();
    expect(find.text('02 / 02'), findsOneWidget);
    // Standard Material ink feedback may finish its opacity transition;
    // the carousel itself must already be on the next page after one frame.
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(
  Widget child, {
  double scale = 1,
  bool dark = false,
  bool reducedMotion = false,
}) => MaterialApp(
  theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: reducedMotion,
    ),
    child: child!,
  ),
  home: Scaffold(body: child),
);

MediaItem _item(
  String id, {
  String? title,
  String author = '',
  String ep = '',
}) => MediaItem(
  id: id,
  title: title ?? '故事 $id',
  cover: '',
  author: author,
  badge: '',
  ep: ep,
  kind: 'book',
);
