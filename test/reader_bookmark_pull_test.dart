import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_bookmark_pull.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';

const _bodyKey = ValueKey('pull-body');
const _contentKey = ValueKey('reader-bookmark-content');
const _savedKey = ValueKey('reader-bookmark-saved-ribbon');

double _translation(WidgetTester tester) => tester
    .widget<Transform>(find.byKey(_contentKey))
    .transform
    .getTranslation()
    .y;

Future<TestGesture> _pull(WidgetTester tester, {double distance = 110}) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(_bodyKey)),
  );
  await gesture.moveBy(const Offset(0, 20));
  await gesture.moveBy(Offset(0, distance));
  await tester.pump();
  return gesture;
}

void main() {
  for (final deleting in [false, true]) {
    testWidgets(
      'persisted ${deleting ? 'delete' : 'add'} does not cut off the return animation',
      (tester) async {
        final saved = ValueNotifier(deleting);
        addTearDown(saved.dispose);
        await _mount(
          tester,
          isBookmarked: saved,
          onAdd: () async {
            saved.value = true;
          },
          onRemove: () async {
            saved.value = false;
          },
        );
        final gesture = await _pull(tester, distance: 160);
        final releaseOffset = _translation(tester);
        await gesture.up();
        await tester.pump();
        expect(saved.value, !deleting);
        expect(
          _translation(tester),
          closeTo(releaseOffset, .01),
          reason: '保存状态刷新不能让正文瞬间归位',
        );
        await tester.pump(const Duration(milliseconds: 33));
        final first = _translation(tester);
        expect(first, greaterThan(0));
        expect(first, lessThan(releaseOffset * .6), reason: '松手后迅速收回，而非先停顿');
        await tester.pump(const Duration(milliseconds: 33));
        final second = _translation(tester);
        expect(second, greaterThan(0));
        expect(
          first - second,
          lessThan(releaseOffset - first),
          reason: '回弹后段逐渐减速',
        );
        await tester.pumpAndSettle();
        expect(_translation(tester), 0);
      },
    );
  }

  testWidgets(
    'a new pull takes over the current return position without a jump',
    (tester) async {
      var saves = 0;
      await _mount(tester, onAdd: () async => saves++);
      await (await _pull(tester, distance: 40)).up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final returning = _translation(tester);
      expect(returning, greaterThan(0));
      final gesture = await _pull(tester, distance: 2);
      expect(_translation(tester), greaterThanOrEqualTo(returning));
      expect(_translation(tester), lessThan(returning + 20));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(_translation(tester), 0);
    },
  );

  testWidgets(
    'whole page follows the finger with damping and returns on release',
    (tester) async {
      var saves = 0;
      await _mount(tester, onAdd: () async => saves++);
      final originalTop = tester.getTopLeft(find.byKey(_bodyKey)).dy;
      final short = await _pull(tester, distance: 40);
      final offset = _translation(tester);
      expect(offset, greaterThan(0));
      expect(offset, lessThan(60));
      expect(tester.getTopLeft(find.byKey(_bodyKey)).dy, originalTop + offset);
      expect(
        find.byKey(const ValueKey('reader-bookmark-backing')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-bookmark-pull-ribbon')),
        findsOneWidget,
      );
      expect(find.text('下拉添加书签'), findsOneWidget);
      expect(saves, 0);
      await short.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(_translation(tester), greaterThan(0));
      expect(_translation(tester), lessThan(offset));
      await tester.pumpAndSettle();
      expect(_translation(tester), 0);
      expect(saves, 0);
      expect(find.text('下拉添加书签'), findsNothing);

      final pull = await _pull(tester);
      expect(find.text('松手添加书签'), findsOneWidget);
      expect(saves, 0);
      await pull.up();
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(_translation(tester), 0);
      expect(find.text('松手添加书签'), findsNothing);
    },
  );

  testWidgets(
    'early and accepted cancel, reversed, upward and disabled pulls never add',
    (tester) async {
      var saves = 0;
      final enabled = ValueNotifier(true);
      addTearDown(enabled.dispose);
      await _mount(tester, enabled: enabled, onAdd: () async => saves++);
      final body = find.byKey(_bodyKey);
      final cancelled = await tester.startGesture(tester.getCenter(body));
      await cancelled.moveBy(const Offset(0, 5));
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(saves, 0);

      // Accepted OS pointer cancellation must not be treated as drag release.
      final armed = await _pull(tester);
      expect(find.text('松手添加书签'), findsOneWidget);
      await armed.cancel();
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(_translation(tester), 0);

      final withdrawn = await _pull(tester);
      expect(find.text('松手添加书签'), findsOneWidget);
      await withdrawn.moveBy(const Offset(0, -130));
      await tester.pump();
      expect(find.text('松手添加书签'), findsNothing);
      await withdrawn.up();
      await tester.pumpAndSettle();
      expect(saves, 0);

      await tester.drag(body, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(_translation(tester), 0);

      final interrupted = await _pull(tester);
      enabled.value = false;
      await tester.pump();
      expect(find.text('松手添加书签'), findsNothing);
      expect(_translation(tester), 0);
      await interrupted.up();
      await tester.pumpAndSettle();
      await tester.drag(body, const Offset(0, 180));
      await tester.pumpAndSettle();
      expect(saves, 0);
    },
  );

  testWidgets('pending save suppresses duplicates and allows a later pull', (
    tester,
  ) async {
    var saves = 0;
    final pending = Completer<void>();
    await _mount(
      tester,
      onAdd: () {
        saves++;
        return saves == 1 ? pending.future : Future<void>.value();
      },
    );
    await (await _pull(tester)).up();
    await tester.pumpAndSettle();
    expect(saves, 1);
    final duplicate = await _pull(tester);
    expect(_translation(tester), 0);
    await duplicate.up();
    await tester.pumpAndSettle();
    expect(saves, 1);
    pending.complete();
    await tester.pump();
    await (await _pull(tester)).up();
    await tester.pumpAndSettle();
    expect(saves, 2);
  });

  testWidgets('saved page pulls show delete hints and remove only on release', (
    tester,
  ) async {
    var adds = 0;
    var removes = 0;
    final saved = ValueNotifier(true);
    addTearDown(saved.dispose);
    await _mount(
      tester,
      isBookmarked: saved,
      onAdd: () async => adds++,
      onRemove: () async {
        removes++;
        saved.value = false;
      },
    );
    final restingRibbon = tester.getRect(find.byKey(_savedKey));
    expect(restingRibbon.width, 10);
    expect(restingRibbon.height, 72);
    expect(restingRibbon.top, 0);
    expect(restingRibbon.right, tester.getSize(find.byKey(_bodyKey)).width - 4);

    final short = await _pull(tester, distance: 40);
    expect(find.text('下拉删除书签'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(_savedKey)).height,
      closeTo(72 + _translation(tester), 0.01),
    );
    await short.up();
    await tester.pumpAndSettle();
    expect(removes, 0);
    expect(find.byKey(_savedKey), findsOneWidget);

    final armed = await _pull(tester);
    expect(find.text('松手删除书签'), findsOneWidget);
    expect(find.text('松手添加书签'), findsNothing);
    expect(removes, 0);
    await armed.up();
    await tester.pumpAndSettle();
    expect(removes, 1);
    expect(adds, 0);
    expect(find.byKey(_savedKey), findsNothing);

    await (await _pull(tester)).up();
    await tester.pumpAndSettle();
    expect(adds, 1);
    expect(removes, 1);
  });

  testWidgets('saved page without a remove callback never falls back to add', (
    tester,
  ) async {
    var adds = 0;
    final saved = ValueNotifier(true);
    addTearDown(saved.dispose);
    await _mount(tester, isBookmarked: saved, onAdd: () async => adds++);
    await (await _pull(tester)).up();
    await tester.pumpAndSettle();
    expect(adds, 0);
    expect(find.byKey(_savedKey), findsOneWidget);
  });

  for (final paged in [true, false]) {
    for (final initiallySaved in [false, true]) {
      for (final interruption in ['cancel', 'location', 'state', 'disabled']) {
        testWidgets(
          '${paged ? 'paged' : 'scroll'} ${initiallySaved ? 'delete' : 'add'} '
          '$interruption aborts the entire gesture',
          (tester) async {
            var adds = 0;
            var removes = 0;
            final saved = ValueNotifier(initiallySaved);
            final location = ValueNotifier<Object?>(('book', 1, 1, 'source'));
            final enabled = ValueNotifier(true);
            addTearDown(saved.dispose);
            addTearDown(location.dispose);
            addTearDown(enabled.dispose);
            await _mount(
              tester,
              paged: paged,
              enabled: enabled,
              isBookmarked: saved,
              locationKey: location,
              onAdd: () async => adds++,
              onRemove: () async => removes++,
            );
            final pull = await _pull(tester, distance: paged ? 110 : 220);
            expect(
              find.text(initiallySaved ? '松手删除书签' : '松手添加书签'),
              findsOneWidget,
            );
            switch (interruption) {
              case 'cancel':
                await pull.cancel();
                break;
              case 'location':
                location.value = ('book', 1, 2, 'source');
                break;
              case 'state':
                saved.value = !initiallySaved;
                break;
              case 'disabled':
                enabled.value = false;
                break;
            }
            await tester.pumpAndSettle();
            expect(_translation(tester), 0);
            if (interruption != 'cancel') {
              // Returning to the original state must not revive an old pull.
              saved.value = initiallySaved;
              location.value = ('book', 1, 1, 'source');
              enabled.value = true;
              await tester.pump();
              await pull.moveBy(const Offset(0, 180));
              await tester.pump();
              expect(_translation(tester), 0);
              await pull.up();
            }
            await tester.pumpAndSettle();
            expect(adds, 0);
            expect(removes, 0);

            // The next pointer sequence may act on the current page.
            await (await _pull(tester, distance: paged ? 110 : 220)).up();
            await tester.pumpAndSettle();
            expect(adds, initiallySaved ? 0 : 1);
            expect(removes, initiallySaved ? 1 : 0);
          },
        );
      }
    }
  }

  testWidgets(
    'reversing an armed delete and pulling while disabled never remove',
    (tester) async {
      var removes = 0;
      final saved = ValueNotifier(true);
      final enabled = ValueNotifier(true);
      addTearDown(saved.dispose);
      addTearDown(enabled.dispose);
      await _mount(
        tester,
        enabled: enabled,
        isBookmarked: saved,
        onAdd: () async {},
        onRemove: () async => removes++,
      );
      final pull = await _pull(tester);
      await pull.moveBy(const Offset(0, -180));
      await pull.up();
      await tester.pumpAndSettle();
      expect(removes, 0);
      enabled.value = false;
      await tester.pump();
      await (await _pull(tester)).up();
      await tester.pumpAndSettle();
      expect(removes, 0);
      expect(_translation(tester), 0);
    },
  );

  testWidgets('hidden saved ribbon still exposes the pull indicator', (
    tester,
  ) async {
    final saved = ValueNotifier(true);
    addTearDown(saved.dispose);
    await _mount(
      tester,
      isBookmarked: saved,
      showSavedRibbon: false,
      onAdd: () async {},
      onRemove: () async {},
    );
    final exposed = find.byKey(const ValueKey('reader-bookmark-pull-ribbon'));
    expect(find.byKey(_savedKey), findsNothing);
    expect(exposed, findsNothing);
    final pull = await _pull(tester);
    expect(find.text('松手删除书签'), findsOneWidget);
    expect(find.byKey(_savedKey), findsNothing);
    expect(exposed, findsOneWidget);
    expect(tester.getSize(exposed).width, 10);
    expect(tester.getSize(exposed).height, closeTo(_translation(tester), 0.01));
    await pull.cancel();
    await tester.pumpAndSettle();
    expect(exposed, findsNothing);
  });

  testWidgets(
    'pending deletion suppresses duplicates and allows a later pull',
    (tester) async {
      var removes = 0;
      final pending = Completer<void>();
      final saved = ValueNotifier(true);
      addTearDown(saved.dispose);
      await _mount(
        tester,
        isBookmarked: saved,
        onAdd: () async {},
        onRemove: () {
          removes++;
          return removes == 1 ? pending.future : Future<void>.value();
        },
      );
      await (await _pull(tester)).up();
      await tester.pumpAndSettle();
      expect(removes, 1);
      final duplicate = await _pull(tester);
      expect(_translation(tester), 0);
      await duplicate.up();
      await tester.pumpAndSettle();
      expect(removes, 1);
      pending.complete();
      await tester.pump();
      await (await _pull(tester)).up();
      await tester.pumpAndSettle();
      expect(removes, 2);
    },
  );

  testWidgets('horizontal paging keeps its own gesture', (tester) async {
    var saves = 0;
    var page = 0;
    await _mount(
      tester,
      onAdd: () async => saves++,
      child: PageView(
        key: _bodyKey,
        onPageChanged: (value) => page = value,
        children: const [Text('第一页'), Text('第二页')],
      ),
    );
    await tester.drag(find.byKey(_bodyKey), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(page, 1);
    expect(saves, 0);
    expect(_translation(tester), 0);
  });

  for (final physics in <ScrollPhysics>[
    const ClampingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
    const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
  ]) {
    testWidgets('${physics.runtimeType}: only top overscroll adds on release', (
      tester,
    ) async {
      var saves = 0;
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await _mount(
        tester,
        paged: false,
        physics: physics,
        controller: controller,
        onAdd: () async => saves++,
      );
      final body = find.byKey(_bodyKey);
      controller.jumpTo(500);
      await tester.pump();
      await tester.drag(body, const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(controller.offset, lessThan(500));
      expect(controller.offset, greaterThan(0));
      expect(saves, 0);
      expect(_translation(tester), 0);

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      await tester.drag(body, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(_translation(tester), 0);

      controller.jumpTo(0);
      await tester.pump();
      final cancelled = await _pull(tester, distance: 220);
      expect(find.text('松手添加书签'), findsOneWidget);
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(saves, 0);

      final reverse = await _pull(tester, distance: 220);
      await reverse.moveBy(const Offset(0, -280));
      await reverse.up();
      await tester.pumpAndSettle();
      expect(saves, 0);

      controller.jumpTo(0);
      await tester.pump();
      final pull = await _pull(tester, distance: 220);
      expect(find.text('松手添加书签'), findsOneWidget);
      expect(_translation(tester), greaterThan(0));
      expect(saves, 0);
      await pull.up();
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(controller.offset, closeTo(0, 0.01));
      expect(_translation(tester), 0);
    });
  }

  for (final physics in <ScrollPhysics>[
    const ClampingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
    const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
  ]) {
    testWidgets(
      '${physics.runtimeType}: saved top overscroll removes on release',
      (tester) async {
        var removes = 0;
        final saved = ValueNotifier(true);
        final controller = ScrollController();
        addTearDown(saved.dispose);
        addTearDown(controller.dispose);
        await _mount(
          tester,
          paged: false,
          physics: physics,
          controller: controller,
          isBookmarked: saved,
          onAdd: () async => fail('A saved page must never invoke onAdd'),
          onRemove: () async => removes++,
        );
        controller.jumpTo(500);
        await tester.pump();
        await tester.drag(find.byKey(_bodyKey), const Offset(0, 120));
        await tester.pumpAndSettle();
        expect(removes, 0);
        expect(_translation(tester), 0);

        controller.jumpTo(0);
        await tester.pump();
        final pull = await _pull(tester, distance: 220);
        expect(find.text('松手删除书签'), findsOneWidget);
        expect(removes, 0);
        await pull.up();
        await tester.pumpAndSettle();
        expect(removes, 1);
        expect(controller.offset, closeTo(0, 0.01));
        expect(_translation(tester), 0);
      },
    );
  }

  testWidgets(
    'saved ribbon follows parent page state even with pull disabled',
    (tester) async {
      final saved = ValueNotifier(false);
      final enabled = ValueNotifier(true);
      addTearDown(saved.dispose);
      addTearDown(enabled.dispose);
      await _mount(
        tester,
        isBookmarked: saved,
        enabled: enabled,
        onAdd: () async {
          saved.value = true;
        },
      );
      expect(find.byKey(_savedKey), findsNothing);
      await (await _pull(tester)).up();
      await tester.pumpAndSettle();
      expect(find.byKey(_savedKey), findsOneWidget);
      expect(find.bySemanticsLabel('当前页已添加书签'), findsOneWidget);
      enabled.value = false;
      await tester.pump();
      expect(find.byKey(_savedKey), findsOneWidget);
      saved.value = false;
      await tester.pump();
      expect(find.byKey(_savedKey), findsNothing);
    },
  );

  for (final preset in [ReaderThemePreset.dark, ReaderThemePreset.eink]) {
    testWidgets('$preset respects safe areas, theme and reduced motion', (
      tester,
    ) async {
      await _mount(
        tester,
        preset: preset,
        media: MediaQueryData(
          size: const Size(375, 812),
          padding: const EdgeInsets.only(top: 44, right: 12),
          disableAnimations: preset != ReaderThemePreset.eink,
        ),
        onAdd: () async {},
      );
      final pull = await _pull(tester, distance: 200);
      final hint = tester.getRect(find.text('松手添加书签'));
      final ribbon = tester.getRect(
        find.byKey(const ValueKey('reader-bookmark-pull-ribbon')),
      );
      expect(hint.top, greaterThanOrEqualTo(44));
      expect(hint.right, lessThanOrEqualTo(ribbon.left));
      final color = tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('reader-bookmark-backing')),
          )
          .color;
      if (preset == ReaderThemePreset.eink) {
        expect(color, Colors.white);
      } else {
        expect(color.computeLuminance(), lessThan(0.1));
        expect(color, isNot(preset.backgroundColor));
      }
      await pull.up();
      await tester.pump();
      expect(_translation(tester), 0);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _mount(
  WidgetTester tester, {
  required Future<void> Function() onAdd,
  ValueNotifier<bool>? enabled,
  ValueNotifier<bool>? isBookmarked,
  ValueNotifier<Object?>? locationKey,
  Future<void> Function()? onRemove,
  bool showSavedRibbon = true,
  bool paged = true,
  ScrollController? controller,
  ScrollPhysics physics = const ClampingScrollPhysics(
    parent: AlwaysScrollableScrollPhysics(),
  ),
  ReaderThemePreset preset = ReaderThemePreset.light,
  MediaQueryData? media,
  Widget? child,
}) async {
  Widget build(bool active, bool saved, Object? location) => ReaderBookmarkPull(
    enabled: active,
    paged: paged,
    preset: preset,
    isBookmarked: saved,
    locationKey: location,
    showSavedRibbon: showSavedRibbon,
    onAdd: onAdd,
    onRemove: onRemove,
    child:
        child ??
        (paged
            ? const ColoredBox(
                key: _bodyKey,
                color: Colors.transparent,
                child: SizedBox.expand(),
              )
            : ListView.builder(
                key: _bodyKey,
                controller: controller,
                physics: physics,
                itemExtent: 80,
                itemCount: 50,
                itemBuilder: (_, index) => Text('段落 $index'),
              )),
  );
  Widget locationBuilder(bool active, bool saved) => locationKey == null
      ? build(active, saved, null)
      : ValueListenableBuilder<Object?>(
          valueListenable: locationKey,
          builder: (_, value, _) => build(active, saved, value),
        );
  Widget savedBuilder(bool active) => isBookmarked == null
      ? locationBuilder(active, false)
      : ValueListenableBuilder<bool>(
          valueListenable: isBookmarked,
          builder: (_, value, _) => locationBuilder(active, value),
        );
  final body = enabled == null
      ? savedBuilder(true)
      : ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, value, _) => savedBuilder(value),
        );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: media == null ? body : MediaQuery(data: media, child: body),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
