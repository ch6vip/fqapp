import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/reader_tap_zones.dart';
import 'package:fqapp/widgets/reader/reader_tap_zone_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Future<List<ReaderTapZoneAction>?>> openEditor(
    WidgetTester tester,
    List<ReaderTapZoneAction> initial,
  ) async {
    // The editor dialog plus the action picker bottom sheet are taller than
    // the default 800x600 test surface; give the test a phone-sized viewport.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<List<ReaderTapZoneAction>?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              result = showReaderTapZoneEditor(
                context: context,
                initialZones: initial,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result!;
  }

  testWidgets('tapping a cell and picking an action changes that cell', (
    tester,
  ) async {
    final pending = await openEditor(tester, defaultReaderTapZones);
    // Top-left cell shows 上一页; change it to 下一章.
    await tester.tap(find.text('上一页').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    final zones = await pending;
    expect(zones, isNotNull);
    expect(zones![0], ReaderTapZoneAction.nextChapter);
    expect(zones.sublist(1), defaultReaderTapZones.sublist(1));
  });

  testWidgets('one-hand preset turns both side columns into next page', (
    tester,
  ) async {
    final pending = await openEditor(tester, defaultReaderTapZones);
    await tester.tap(find.text('单手模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(await pending, oneHandReaderTapZones);
  });

  testWidgets('fullscreen preset turns every cell but the center into next '
      'page', (tester) async {
    final pending = await openEditor(tester, defaultReaderTapZones);
    await tester.tap(find.text('全屏翻页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(await pending, fullscreenReaderTapZones);
  });

  testWidgets('closing without 完成 discards the edits', (tester) async {
    final pending = await openEditor(tester, defaultReaderTapZones);
    await tester.tap(find.text('单手模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(await pending, isNull);
  });

  testWidgets('no-menu grid regains a menu zone in the center on 完成', (
    tester,
  ) async {
    final allNext = List<ReaderTapZoneAction>.filled(
      9,
      ReaderTapZoneAction.nextPage,
    );
    final pending = await openEditor(tester, allNext);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    final zones = await pending;
    expect(zones, isNotNull);
    expect(zones![4], ReaderTapZoneAction.menu);
  });
}
