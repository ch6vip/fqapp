import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_appearance_sheet.dart';
import 'package:fqapp/widgets/reader/reader_scroll_mode_setting.dart';
import 'package:fqapp/widgets/reader/settings/reader_more_settings_sheet.dart';
import 'package:fqapp/widgets/reader/settings/reader_settings_widgets.dart';

import 'support/reader_settings_nav.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'an explicit direct-switch choice survives normalization and other edits',
    () async {
      await const ReaderPreferences(
        scrollChapterMode: ReaderScrollChapterMode.replace,
      ).copyWith(fontSize: 24).normalized().save();
      expect(
        (await ReaderPreferences.load()).scrollChapterMode,
        ReaderScrollChapterMode.replace,
      );
    },
  );

  testWidgets(
    'scrolling reveals the cross-chapter row directly below page turning',
    (tester) async {
      final changes = await _openSheet(tester);
      await openReaderSettingsCategory(tester, 'turn');
      expect(find.byType(ReaderScrollModeSetting), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reader-mode-scroll')));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('reader-scroll-chapter-mode'));
      expect(row, findsOneWidget);
      expect(find.text('跨章'), findsOneWidget);
      // 跨章设置紧跟转页 chips，位于自动翻页之前。
      expect(
        tester.getRect(row).top,
        greaterThan(tester.getRect(find.text('仿真')).bottom),
      );
      expect(
        tester.getRect(row).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const ValueKey('reader-auto-turn'))).top,
        ),
      );
      final joined = tester.widget<ReaderSettingsChip>(
        find.byKey(const ValueKey('reader-cross-chapter-joined')),
      );
      expect(joined.selected, isTrue);
      expect(changes.last.scrollChapterMode, ReaderScrollChapterMode.joined);
    },
  );

  testWidgets(
    'all paged styles hide the row and returning to scroll retains the choice',
    (tester) async {
      final changes = await _openSheet(
        tester,
        initial: const ReaderPreferences(pageMode: ReaderPageMode.scroll),
      );
      await openReaderSettingsCategory(tester, 'turn');
      await tester.tap(
        find.byKey(const ValueKey('reader-cross-chapter-replace')),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(changes.last.scrollChapterMode, ReaderScrollChapterMode.replace);
      for (final key in [
        'reader-turn-curl',
        'reader-mode-paged',
        'reader-turn-slide',
      ]) {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        expect(find.byType(ReaderScrollModeSetting), findsNothing, reason: key);
        await tester.tap(find.byKey(const ValueKey('reader-mode-scroll')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ReaderSettingsChip>(
                find.byKey(const ValueKey('reader-cross-chapter-replace')),
              )
              .selected,
          isTrue,
        );
      }
    },
  );

  testWidgets('no-animation paging has no cross-chapter row', (tester) async {
    await _openSheet(
      tester,
      initial: const ReaderPreferences(
        pageTurnStyle: ReaderPageTurnStyle.none,
        instantSwipeTurn: true,
      ),
    );
    await openReaderSettingsCategory(tester, 'turn');
    expect(find.byType(ReaderScrollModeSetting), findsNothing);
  });

  testWidgets('more settings no longer duplicates the cross-chapter choices', (
    tester,
  ) async {
    await _openSheet(
      tester,
      initial: const ReaderPreferences(pageMode: ReaderPageMode.scroll),
    );
    // 「翻页」分类里的行为面板就是原来的更多设置。
    await openReaderSettingsCategory(tester, 'turn');
    expect(find.byType(ReaderMoreSettingsSheet), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ReaderMoreSettingsSheet),
        matching: find.byType(ReaderScrollModeSetting),
      ),
      findsNothing,
    );
  });
}

Future<List<ReaderPreferences>> _openSheet(
  WidgetTester tester, {
  ReaderPreferences initial = const ReaderPreferences(),
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final changes = <ReaderPreferences>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showReaderSettingsSheet(
              context: context,
              initialValue: initial,
              onChanged: changes.add,
              onPickFont: () async => null,
              deviceAvailable: true,
              systemBrightness: .45,
              onBrightness: (_) {},
              onBrightnessEnd: () {},
              onFollowSystem: () {},
              autoTurnActive: false,
              onAutoTurn: null,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return changes;
}
