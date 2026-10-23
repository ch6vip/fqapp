import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/home/home_cell_blocks.dart';

/// S1 acceptance: the block frame must match `as_.xml`.
///
/// These pin the numbers that make the official page look like the official
/// page — a white 8dp card floating on `#F6F6F6`, an `as_` (not `bqe`) title,
/// and the 「更多书籍信息」 strip. A later "tidy up" that reverts any of them
/// should fail here rather than silently ship.
void main() {
  MediaItem book(int index) => MediaItem(
    id: 'b$index',
    title: '书$index',
    cover: '',
    author: '',
    badge: '',
    ep: '',
    kind: 'book',
  );

  HomeCell cell({String name = '猜你喜欢', int count = 4}) => HomeCell(
    showType: 385,
    name: name,
    id: 'cell-test',
    style: const {},
    items: [for (var i = 0; i < count; i++) book(i)],
    children: const [],
  );

  /// Pumps [child] and hands back a live context below it.
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    );
  }

  /// Pumps the result of [build], which needs a real [BuildContext].
  Future<void> pumpWithContext(
    WidgetTester tester,
    Widget Function(BuildContext) build,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Builder(builder: (context) => build(context)),
          ),
        ),
      ),
    );
  }

  group('HomeBlockCard', () {
    testWidgets('is white with 8dp corners and 16/14 outer margin', (
      tester,
    ) async {
      await pump(
        tester,
        const HomeBlockCard(child: SizedBox(height: 40, width: 10)),
      );

      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(HomeBlockCard),
          matching: find.byType(Container),
        ),
      );

      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, const Color(0xFFFFFFFF));
      expect(decoration.borderRadius, BorderRadius.circular(blockCornerRadius));
      // `8.0dip` from skin_bg_new_book_mall_cell_light.xml.
      expect(blockCornerRadius, 8);

      // `as_.xml` root margins: 16dp sides, 14dp bottom, no top.
      expect(container.margin, const EdgeInsets.fromLTRB(16, 0, 16, 14));
    });

    testWidgets('clips its child to the rounded corners', (tester) async {
      await pump(
        tester,
        const HomeBlockCard(child: SizedBox(height: 40, width: 10)),
      );
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(HomeBlockCard),
          matching: find.byType(Container),
        ),
      );
      expect(container.clipBehavior, Clip.antiAlias);
    });
  });

  group('HomeSectionTitle', () {
    testWidgets('uses the as_ header padding, not bqe', (tester) async {
      await pump(tester, const HomeSectionTitle(title: '排行榜'));

      // `as_.xml` `b07`: top 24 / bottom 14 / start 16 / end 32.
      // `bqe.xml` would be 20/12 — a regression to that template fails here.
      expect(HomeSectionTitle.padding, const EdgeInsets.fromLTRB(16, 24, 32, 14));

      final text = tester.widget<Text>(find.text('排行榜'));
      expect(text.style!.fontSize, 18);
      expect(text.style!.fontWeight, FontWeight.w700);
      expect(text.maxLines, 1);
    });
  });

  group('HomeBlockMoreBooks', () {
    testWidgets('is a 40dp strip with the official label', (tester) async {
      await pump(tester, const HomeBlockMoreBooks());

      // `jd.xml`: `anz` 14sp + 5x8 chevron in a 40dp frame.
      final box = tester.widget<SizedBox>(
        find
            .descendant(
              of: find.byType(HomeBlockMoreBooks),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      expect(box.height, 40);

      final text = tester.widget<Text>(find.text('更多书籍信息'));
      expect(text.style!.fontSize, 14);
    });

    testWidgets('forwards taps when a callback is given', (tester) async {
      var taps = 0;
      await pump(tester, HomeBlockMoreBooks(onTap: () => taps++));

      await tester.tap(find.text('更多书籍信息'));
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('block composition', () {
    testWidgets('a grid block renders title, cards and the more strip', (
      tester,
    ) async {
      final block = cell();
      await pumpWithContext(
        tester,
        (context) => buildCardSection(
          context,
          block,
          onOpen: (_) {},
          gridWidth: 368,
        ),
      );

      expect(find.byType(HomeBlockCard), findsOneWidget);
      expect(find.text('猜你喜欢'), findsOneWidget);
      expect(find.text('更多书籍信息'), findsOneWidget);
      // Four books in the cell, four cards rendered.
      expect(find.byType(HomeBookCard), findsNWidgets(4));
    });

    testWidgets('hide_title blocks drop the title but keep the strip', (
      tester,
    ) async {
      final block = cell(name: '');
      await pumpWithContext(
        tester,
        (context) => buildCardSection(
          context,
          block,
          onOpen: (_) {},
          gridWidth: 368,
        ),
      );

      expect(find.byType(HomeSectionTitle), findsNothing);
      expect(find.text('更多书籍信息'), findsOneWidget);
    });
  });

  group('homeColumnCount', () {
    /// Reads [homeColumnCount] under an explicit [MediaQuery] size.
    ///
    /// `MediaQuery.sizeOf` is the dp size the widget sees, so wrapping it
    /// directly is both deterministic and independent of the test surface.
    Future<int> columnsAt(
      WidgetTester tester,
      Size size, {
      required bool padAdapt,
    }) async {
      late int columns;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: Builder(
            builder: (context) {
              columns = homeColumnCount(context, padAdapt: padAdapt);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return columns;
    }

    /// `us3.a.q()` only leaves the 2-column branch when the pad-adapt flag
    /// (`b()`) is on, so a phone must stay at 2 for every width.
    testWidgets('phone stays at 2 columns regardless of width', (tester) async {
      for (final width in [320.0, 400.0, 500.0, 700.0, 1400.0]) {
        expect(
          await columnsAt(tester, Size(width, 900), padAdapt: false),
          2,
          reason: 'padAdapt defaults to false, so q() returns 2 at ${width}dp',
        );
      }
    });

    testWidgets('pad adapt follows the 516/1024/1366 breakpoints', (
      tester,
    ) async {
      // `q()` reads the screen's *short* side, so the shorter dimension has to
      // be the one under test. Each case is fed as (target, target + 100).
      final cases = <double, int>{
        400: 2,
        515: 2,
        516: 3,
        1023: 3,
        1024: 4,
        1365: 4,
        1366: 5,
      };
      for (final entry in cases.entries) {
        expect(
          await columnsAt(
            tester,
            Size(entry.key, entry.key + 100),
            padAdapt: true,
          ),
          entry.value,
          reason: 'padAdapt at ${entry.key}dp short side',
        );
      }
    });
  });
}
