import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_appearance_sheet.dart';
import 'package:fqapp/widgets/reader/reader_controls.dart';
import 'package:fqapp/widgets/reader/settings/reader_settings_widgets.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  group('opening from the reading menu', () {
    testWidgets('设置 opens the reading settings sheet directly', (tester) async {
      await _mountReader(tester);
      await _openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();

      expect(find.text('阅读设置'), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-brightness')), findsOneWidget);
      expect(find.text('排版'), findsNothing);
    });

    testWidgets('the reading menu is visible again after closing the sheet', (
      tester,
    ) async {
      await _mountReader(tester);
      await _openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('reader-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderControls), findsOneWidget);

      await tester.tap(find.byTooltip('关闭排版设置'));
      await tester.pumpAndSettle();

      expect(find.text('阅读设置'), findsNothing);
      expect(find.byType(ReaderControls), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-controls')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('翻页 chips', () {
    testWidgets('滚动 sets scroll mode and a paged chip restores paging', (
      tester,
    ) async {
      final changes = await _openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('reader-mode-scroll')));
      await tester.pumpAndSettle();
      expect(changes.last.pageMode, ReaderPageMode.scroll);

      await tester.tap(find.byKey(const ValueKey('reader-mode-paged')));
      await tester.pumpAndSettle();
      expect(changes.last.pageMode, ReaderPageMode.paged);
      expect(changes.last.pageTurnStyle, ReaderPageTurnStyle.cover);
    });

    testWidgets('no paged-style chip is selected with no-animation paging', (
      tester,
    ) async {
      await _openSheet(
        tester,
        initial: const ReaderPreferences(
          pageTurnStyle: ReaderPageTurnStyle.none,
          instantSwipeTurn: true,
        ),
      );

      for (final key in const [
        'reader-turn-curl',
        'reader-mode-paged',
        'reader-turn-slide',
      ]) {
        final chip = tester.widget<ReaderSettingsChip>(
          find.byKey(ValueKey(key)),
        );
        expect(chip.selected, isFalse, reason: key);
      }
      final scroll = tester.widget<ReaderSettingsChip>(
        find.byKey(const ValueKey('reader-mode-scroll')),
      );
      expect(scroll.selected, isFalse);
    });
  });

  group('间距 presets', () {
    testWidgets('a preset sets line height, paragraph and both paddings', (
      tester,
    ) async {
      final changes = await _openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('reader-spacing-loose')));
      await tester.pumpAndSettle();
      final loose = changes.last;
      expect(loose.lineHeight, 2.1);
      expect(loose.paragraphSpacing, 20);
      expect(loose.horizontalPadding, 32);
      expect(loose.verticalPadding, 28);

      await tester.tap(find.byKey(const ValueKey('reader-spacing-compact')));
      await tester.pumpAndSettle();
      final compact = changes.last;
      expect(compact.lineHeight, 1.5);
      expect(compact.paragraphSpacing, 6);
      expect(compact.horizontalPadding, 12);
      expect(compact.verticalPadding, 8);
    });

    testWidgets('标准 is selected only for the default values', (tester) async {
      await _openSheet(tester);
      final standard = tester.widget<ReaderSettingsChip>(
        find.byKey(const ValueKey('reader-spacing-standard')),
      );
      expect(standard.selected, isTrue);
    });

    testWidgets('custom spacing selects none of the presets', (tester) async {
      await _openSheet(
        tester,
        initial: const ReaderPreferences(
          lineHeight: 1.9,
          paragraphSpacing: 14,
          horizontalPadding: 22,
          verticalPadding: 20,
        ),
      );
      for (final key in const [
        'reader-spacing-compact',
        'reader-spacing-standard',
        'reader-spacing-loose',
      ]) {
        final chip = tester.widget<ReaderSettingsChip>(
          find.byKey(ValueKey(key)),
        );
        expect(chip.selected, isFalse, reason: key);
      }
    });
  });

  group('更多设置', () {
    testWidgets(
      'restoring defaults under the e-ink lock keeps the saved preset',
      (tester) async {
        final changes = await _openSheet(
          tester,
          initial: const ReaderPreferences(
            themePreset: ReaderThemePreset.dark,
            brightness: 0.7,
            followSystemBrightness: false,
          ),
          einkOverride: true,
        );

        await tester.ensureVisible(
          find.byKey(const ValueKey('reader-more-appearance')),
        );
        await tester.tap(find.byKey(const ValueKey('reader-more-appearance')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('reader-more-settings-scroll')),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('reader-restore-defaults')),
        );
        await tester.tap(find.byKey(const ValueKey('reader-restore-defaults')));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();

        expect(changes, isNotEmpty);
        expect(changes.last.themePreset, ReaderThemePreset.dark);
        expect(changes.last.brightness, 0.7);
        expect(changes.last.followSystemBrightness, isFalse);
      },
    );

    testWidgets('整屏刷新 shows for the e-ink preset and hides otherwise', (
      tester,
    ) async {
      await _openSheet(
        tester,
        initial: const ReaderPreferences(themePreset: ReaderThemePreset.eink),
      );
      await tester.tap(find.byKey(const ValueKey('reader-more-appearance')));
      await tester.pumpAndSettle();
      expect(find.text('整屏刷新'), findsOneWidget);
      expect(find.byKey(const ValueKey('einkRefreshInterval')), findsOneWidget);
    });

    testWidgets('整屏刷新 stays hidden outside e-ink', (tester) async {
      await _openSheet(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-appearance')));
      await tester.pumpAndSettle();
      expect(find.text('整屏刷新'), findsNothing);
    });
  });

  group('layout', () {
    for (final layout in [
      (name: 'portrait', size: const Size(390, 844), scale: 1.0),
      (name: 'narrow large text', size: const Size(280, 600), scale: 2.0),
      (name: 'landscape', size: const Size(780, 360), scale: 1.4),
    ]) {
      testWidgets('settings sheet fits ${layout.name}', (tester) async {
        await _openSheet(tester, size: layout.size, scale: layout.scale);
        expect(tester.takeException(), isNull);

        for (final label in const ['仿真', '覆盖', '平移', '滚动', '紧凑', '标准', '宽松']) {
          final finder = find.text(label);
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          expect(finder.hitTestable(), findsOneWidget, reason: label);
          expect(tester.getSize(finder).width, greaterThan(0), reason: label);
        }
        expect(tester.takeException(), isNull);
      });
    }

    // 回归：chip 曾因 Container.alignment 撑满宽度，在手机上每个选项独占一行。
    testWidgets('option chips share one line on a normal phone', (
      tester,
    ) async {
      await _openSheet(tester);
      for (final group in const [
        ['仿真', '覆盖', '平移', '滚动'],
        ['紧凑', '标准', '宽松'],
      ]) {
        final top = tester.getCenter(find.text(group.first)).dy;
        for (final label in group.skip(1)) {
          expect(
            tester.getCenter(find.text(label)).dy,
            closeTo(top, 0.5),
            reason: '$label must sit on the same line as ${group.first}',
          );
        }
      }
      await tester.tap(find.byKey(const ValueKey('reader-more-appearance')));
      await tester.pumpAndSettle();
      final weightTop = tester.getCenter(find.text('细')).dy;
      for (final label in const ['适中', '偏粗', '粗']) {
        expect(tester.getCenter(find.text(label)).dy, closeTo(weightTop, 0.5));
      }
      expect(
        tester.getCenter(find.text('居左')).dy,
        closeTo(tester.getCenter(find.text('居中')).dy, 0.5),
      );
    });

    testWidgets('the main sheet fits a normal phone without scrolling', (
      tester,
    ) async {
      await _openSheet(tester);
      final scrollable = find.descendant(
        of: find.byKey(const ValueKey('reader-appearance-scroll')),
        matching: find.byType(Scrollable),
      );
      expect(
        tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
        0,
      );
    });
  });
}

/// 设置测试必须改 View 的尺寸：只改 surface 时 MediaQuery 仍是默认 800x600，
/// 面板按错误屏高算出的最大高度会把内容挤进滚动区。
void _sizeView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _mountReader(WidgetTester tester) async {
  _sizeView(tester, const Size(390, 844));
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderPage(
        bookId: 'settings-sheet-test',
        title: '设置面板测试',
        chapters: [
          Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
          Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
        ],
        startIndex: 0,
        readerDevice: _Device(),
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        chapterLoader: (_) async =>
            List.generate(40, (index) => '第 $index 段用于测试设置面板。').join('\n\n'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
  );
  await tester.pumpAndSettle();
}

/// Builds a screen that opens the real settings sheet, and records every
/// preference value the sheet hands to the reader page.
Future<List<ReaderPreferences>> _openSheet(
  WidgetTester tester, {
  ReaderPreferences initial = const ReaderPreferences(),
  Size size = const Size(390, 844),
  double scale = 1,
  bool einkOverride = false,
  bool oledOverride = false,
}) async {
  _sizeView(tester, size);
  final changes = <ReaderPreferences>[];
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showReaderSettingsSheet(
                context: context,
                initialValue: initial,
                onChanged: changes.add,
                onPickFont: () async => null,
                deviceAvailable: true,
                systemBrightness: 0.45,
                onBrightness: (_) {},
                onBrightnessEnd: () {},
                onFollowSystem: () {},
                autoTurnActive: false,
                onAutoTurn: () {},
                einkOverride: einkOverride,
                oledOverride: oledOverride,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return changes;
}

class _Device extends ReaderDevice {
  final _events = StreamController<ReaderDeviceStatus>.broadcast(sync: true);

  _Device() {
    addTearDown(_events.close);
  }

  @override
  Stream<ReaderDeviceStatus> get changes => _events.stream;

  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 10, 30, 9),
    battery: 80,
    systemBrightness: 0.45,
  );

  @override
  Future<bool> setBrightness({
    required bool followSystem,
    required double brightness,
  }) async => true;

  @override
  Future<void> suspend() async {}

  @override
  Future<void> close() async {}

  @override
  Future<ReaderFont?> pickFont() async => null;
}
