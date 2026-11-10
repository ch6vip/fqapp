import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fqapp/models/fanqie_library_capture.dart';
import 'package:fqapp/models/text_replacement_rule.dart';
import 'package:fqapp/pages/about_page.dart';
import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/pages/fanqie_history_import_page.dart';
import 'package:fqapp/pages/library_backup_page.dart';
import 'package:fqapp/pages/system_tts_settings_page.dart';
import 'package:fqapp/pages/text_replacement_page.dart';
import 'package:fqapp/services/app_log.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/system_tts.dart';
import 'package:fqapp/services/text_replacement_store.dart';
import 'package:fqapp/widgets/settings/settings_adaptive.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';

import 'support/app_ui_host.dart';

/// State, scroll anchoring and layout behaviour the REWORK review found:
/// - a disclosure's expanded flag must live above the card/list item,
/// - a list must stay on the same section when the shell changes,
/// - a failed TTS write must not keep the unsubmitted engine selected,
/// - the archive disclosure must animate (and skip it for reduced motion),
/// - the classic about row must fit 320dp at 2× text.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.light;
    AppLog.instance.resetForTest();
    directory = await Directory.systemTemp.createTemp('fqapp-secondary-state-');
    Hive.init(directory.path);
    await LibraryStore.instance.init();
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    AppLog.instance.resetForTest();
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance =
        InMemorySharedPreferencesStore.empty();
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Temp directory cleanup is noise.
    }
  });

  Future<AppThemeStyleStore> pumpStyled(
    WidgetTester tester,
    Widget page, {
    AppThemeStyle style = AppThemeStyle.classic,
    Size size = const Size(400, 700),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = AppThemeStyleStore()..value = style;
    addTearDown(store.dispose);
    await tester.pumpWidget(AppUiHost(store: store, home: page));
    await tester.pumpAndSettle();
    return store;
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  bool expandedFlag(WidgetTester tester) {
    final semantics = tester.widgetList<Semantics>(
      find.descendant(
        of: find.byType(SettingsDisclosure),
        matching: find.byType(Semantics),
      ),
    );
    return semantics.any((widget) => widget.properties.expanded == true);
  }

  ScrollPosition positionOf(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  void mockBackupChannel(
    WidgetTester tester, {
    Uint8List? open,
    Uint8List? latest,
  }) {
    const channel = MethodChannel('fqapp/library_backup');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'openBackup') return open;
      if (call.method == 'latestFanqieCapture') return latest;
      if (call.method == 'saveBackup') return true;
      if (call.method == 'storeFanqieCapture') return true;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  group('disclosure state', () {
    testWidgets('备份帮助块跨三套主题与滚出视口后仍保持展开', (tester) async {
      mockBackupChannel(tester);
      final store = await pumpStyled(
        tester,
        const LibraryBackupPage(),
        size: const Size(400, 360),
      );

      await scrollTo(tester, find.byKey(const ValueKey('backup-help')));
      await tester.tap(find.text('备份包含哪些内容？'));
      await tester.pumpAndSettle();
      expect(find.textContaining('书架分组'), findsOneWidget);
      expect(expandedFlag(tester), isTrue);

      for (final style in [
        AppThemeStyle.archive,
        AppThemeStyle.classic,
        AppThemeStyle.archive,
      ]) {
        store.value = style;
        await tester.pumpAndSettle();
        await scrollTo(tester, find.byKey(const ValueKey('backup-help')));
        expect(
          find.textContaining('书架分组'),
          findsOneWidget,
          reason: '展开状态在 ${style.name} 下必须保留',
        );
        expect(expandedFlag(tester), isTrue);
      }

      // Scroll the block out of the viewport (the list disposes it) and back.
      await tester.drag(find.byType(ListView).first, const Offset(0, 2000));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('backup-help')), findsNothing);
      await scrollTo(tester, find.byKey(const ValueKey('backup-help')));
      expect(find.textContaining('书架分组'), findsOneWidget);
      expect(expandedFlag(tester), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('番茄采集详情跨三套主题保持展开', (tester) async {
      final capture = FanqieLibraryCapture({
        'format': 'fqapp.fanqie-library-capture',
        'version': 2,
        'sources': [
          {
            'resource': 'shelf_list',
            'status': 'received',
            'payload': {
              'code': 0,
              'data': {
                'book_shelf_info_all': [
                  {'book_id': '101', 'book_type': 0},
                ],
              },
            },
          },
        ],
        'parts': <String>[],
      });
      mockBackupChannel(tester, latest: capture.encode());

      final store = await pumpStyled(
        tester,
        const FanqieHistoryImportPage(),
        size: const Size(400, 700),
      );
      await scrollTo(
        tester,
        find.byKey(const ValueKey('fanqie-capture-details')),
      );
      await tester.tap(find.text('采集详情与文件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('响应数量不是书籍数量'), findsOneWidget);
      expect(expandedFlag(tester), isTrue);

      for (final style in [
        AppThemeStyle.archive,
        AppThemeStyle.classic,
        AppThemeStyle.archive,
      ]) {
        store.value = style;
        await tester.pumpAndSettle();
        await scrollTo(
          tester,
          find.byKey(const ValueKey('fanqie-capture-details')),
        );
        expect(
          find.textContaining('响应数量不是书籍数量'),
          findsOneWidget,
          reason: '采集详情在 ${style.name} 下必须保持展开',
        );
        expect(expandedFlag(tester), isTrue);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('scroll anchor', () {
    /// Switches through both presentations and checks the section keeps its
    /// place on screen (the list must not jump back to the top).
    Future<void> expectAnchored(
      WidgetTester tester,
      AppThemeStyleStore store,
      Finder section, {
      double tolerance = 2,
    }) async {
      // Put the section exactly on the viewport top: it becomes the anchor, so
      // the presentation switch must keep it there (a pixel-only restore would
      // drift by the height difference of the widgets above it).
      await Scrollable.ensureVisible(tester.element(section), alignment: 0);
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(section).dy;
      expect(before, closeTo(0, 1));
      expect(positionOf(tester).pixels, greaterThan(0));
      for (final style in [
        AppThemeStyle.archive,
        AppThemeStyle.classic,
        AppThemeStyle.archive,
      ]) {
        store.value = style;
        await tester.pumpAndSettle();
        expect(section, findsOneWidget, reason: '${style.name} 下同一分区必须仍在列表里');
        expect(
          tester.getTopLeft(section).dy,
          closeTo(before, tolerance),
          reason: '${style.name} 下分区相对视口的位置必须保持',
        );
        expect(positionOf(tester).pixels, greaterThan(0));
      }
    }

    testWidgets('备份列表切主题保持可见分区', (tester) async {
      mockBackupChannel(tester);
      final store = await pumpStyled(
        tester,
        const LibraryBackupPage(),
        size: const Size(400, 500),
      );
      // Expanding the help block keeps enough content below 本机数据 in *both*
      // presentations, so the anchor is reachable in each of them.
      await scrollTo(tester, find.byKey(const ValueKey('backup-help')));
      await tester.tap(find.text('备份包含哪些内容？'));
      await tester.pumpAndSettle();
      // The local section is above the expanded help, outside the lazy cache.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('backup-local-section')),
        -160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await expectAnchored(
        tester,
        store,
        find.byKey(const ValueKey('backup-local-section')),
        tolerance: 1.5,
      );
    });

    testWidgets('番茄列表切主题保持可见分区', (tester) async {
      mockBackupChannel(tester, open: _fanqieHistoryBytes());
      final store = await pumpStyled(
        tester,
        const FanqieHistoryImportPage(),
        size: const Size(400, 500),
      );
      // A history file produces the preview section and makes the list long.
      await tester.tap(find.text('从历史文件导入'));
      await tester.pumpAndSettle();
      expect(find.textContaining('导入预览'), findsOneWidget);
      // The import scrolled the list to the preview; return to the top section
      // before anchoring it.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
      await tester.pumpAndSettle();
      await scrollTo(
        tester,
        find.byKey(const ValueKey('fanqie-sources-section')),
      );
      await expectAnchored(
        tester,
        store,
        find.byKey(const ValueKey('fanqie-sources-section')),
        tolerance: 1.5,
      );
    });

    testWidgets('正文替换列表切主题保持可见规则', (tester) async {
      final replacement = TextReplacementStore();
      await replacement.load();
      await replacement.save(
        enabled: true,
        rules: [
          for (var i = 0; i < 12; i++)
            TextReplacementRule(
              id: 'r$i',
              pattern: '匹配词$i',
              replacement: '替换词$i',
            ),
        ],
      );
      final store = await pumpStyled(
        tester,
        TextReplacementPage(store: replacement),
        size: const Size(400, 500),
      );
      await scrollTo(tester, find.byKey(const ValueKey('replacement-edit-7')));
      await expectAnchored(
        tester,
        store,
        find.byKey(const ValueKey('replacement-edit-7')),
        tolerance: 1.5,
      );
    });

    testWidgets('API 列表切主题保持可见分区', (tester) async {
      // Same list shape in both presentations plus per-section anchors: the
      // section the user was reading keeps its viewport position instead of
      // the list jumping back to the top.
      final store = await pumpStyled(
        tester,
        const ApiServicePage(),
        size: const Size(400, 500),
      );
      await tester.tap(find.text('查看可用接口'));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const ValueKey('api-network-card')));
      await expectAnchored(
        tester,
        store,
        find.byKey(const ValueKey('api-network-card')),
        tolerance: 1.5,
      );
    });

    testWidgets('番茄预览记录标题被回收后仍按内容 ID 保持位置', (tester) async {
      mockBackupChannel(tester, open: _fanqieHistoryBytes());
      final store = await pumpStyled(
        tester,
        const FanqieHistoryImportPage(),
        size: const Size(400, 360),
      );
      await tester.tap(find.text('从历史文件导入'));
      await tester.pumpAndSettle();
      expect(find.textContaining('导入预览'), findsOneWidget);

      final row = find.byKey(const ValueKey('fanqie-record-103'));
      await Scrollable.ensureVisible(tester.element(row), alignment: 0);
      await tester.pumpAndSettle();
      // Stop with the record just above the viewport top: the row is partly
      // visible and the next one is partly visible below it.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -21));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('导入预览'),
        findsNothing,
        reason: 'section 标题必须已经离开列表构建窗口，否则本次用例没有覆盖目标场景',
      );
      final before = tester.getTopLeft(row).dy;
      expect(before, lessThan(0));
      expect(find.text('历史作品 3'), findsOneWidget);
      expect(find.text('历史作品 4'), findsOneWidget, reason: '第四条记录必须部分可见');

      for (final style in [
        AppThemeStyle.archive,
        AppThemeStyle.classic,
        AppThemeStyle.archive,
      ]) {
        final position = positionOf(tester);
        // The anchor has to be recoverable inside the new scroll range, not
        // clamped at a boundary (that would hide a lost anchor).
        expect(position.pixels, greaterThan(position.minScrollExtent));
        expect(position.maxScrollExtent, greaterThan(position.minScrollExtent));
        store.value = style;
        await tester.pumpAndSettle();
        expect(find.textContaining('导入预览'), findsNothing);
        expect(row, findsOneWidget, reason: '${style.name} 下同一记录必须仍在列表里');
        expect(
          tester.getTopLeft(row).dy,
          closeTo(before, 1.5),
          reason: '${style.name} 下记录相对视口的位置必须保持，标题不在构建树时也一样',
        );
        final after = positionOf(tester);
        expect(after.pixels, greaterThan(0));
        expect(after.pixels, lessThan(after.maxScrollExtent));
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('高刷新率下锚点跟随到主题动画结束（60/120/240/360Hz）', (tester) async {
      // The follow-up pass used to be a fixed 24 frames: at 360 Hz that is
      // ~67 ms, short of the 200 ms theme animation, so the target section
      // drifted a few pixels after the pass had already stopped.
      for (final hz in [60, 120, 240, 360]) {
        final store = await pumpStyled(
          tester,
          const ApiServicePage(),
          size: const Size(400, 500),
        );
        await tester.tap(find.text('查看可用接口'));
        await tester.pumpAndSettle();
        final section = find.byKey(const ValueKey('api-network-card'));
        await Scrollable.ensureVisible(tester.element(section), alignment: 0);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(section).dy, closeTo(0, 1));

        store.value = AppThemeStyle.archive;
        // Advance exactly one display frame at a time for longer than the
        // theme animation, so a frame-count window shows up as drift.
        final frame = Duration(microseconds: (1000000 / hz).round());
        final frames = (600 * 1000 / (1000000 / hz)).ceil();
        for (var i = 0; i < frames; i++) {
          await tester.pump(frame);
        }
        expect(
          tester.getTopLeft(section).dy,
          closeTo(0, 1.5),
          reason: '${hz}Hz 下主题动画结束时分区不得残留位移',
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });

  testWidgets('经典 TTS 写失败保留已提交引擎，重试成功后调速不写回旧引擎', (tester) async {
    final preferences = _ToggleFailStore({
      'flutter.system_tts_engine': 'engine.old',
      'flutter.system_tts_rate': 1.0,
    });
    // setUp already cached an empty SharedPreferences instance; reset it so the
    // seeded store is what the page loads.
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = preferences;

    const channel = MethodChannel('fqapp/system_tts');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'engines') {
        return {
          'engines': [
            {'package': 'engine.old', 'label': '旧引擎'},
            {'package': 'engine.new', 'label': '新引擎'},
          ],
          'defaultEngine': 'engine.old',
        };
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final store = await pumpStyled(tester, const SystemTtsSettingsPage());

    DropdownButton<String> dropdown() => tester.widget<DropdownButton<String>>(
      find.byKey(const ValueKey('tts-engine-classic')),
    );

    expect(dropdown().value, 'engine.old');

    // A failed write must keep the committed engine on screen.
    preferences.failWrites = true;
    await tester.tap(find.byKey(const ValueKey('tts-engine-classic')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新引擎').last);
    await tester.pumpAndSettle();
    expect(find.text('设置保存失败，请重试'), findsOneWidget);
    expect(dropdown().value, 'engine.old');

    // Retry succeeds and becomes the committed engine.
    preferences.failWrites = false;
    await tester.tap(find.byKey(const ValueKey('tts-engine-classic')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新引擎').last);
    await tester.pumpAndSettle();
    expect(dropdown().value, 'engine.new');

    // The selection survives a presentation round trip.
    store.value = AppThemeStyle.archive;
    await tester.pumpAndSettle();
    store.value = AppThemeStyle.classic;
    await tester.pumpAndSettle();
    expect(dropdown().value, 'engine.new');

    // A later rate change writes the new engine back, not the old one.
    final slider = find.byType(Slider);
    await tester.drag(slider, const Offset(40, 0));
    await tester.pumpAndSettle();
    final saved = await SystemTtsPreferences.load();
    expect(saved.engine, 'engine.new');
    expect(saved.rate, greaterThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('archive 披露块有高度/箭头动画，减少动态时立即展开', (tester) async {
    mockBackupChannel(tester);
    await pumpStyled(
      tester,
      const LibraryBackupPage(),
      style: AppThemeStyle.archive,
      size: const Size(400, 700),
    );
    await scrollTo(tester, find.byKey(const ValueKey('backup-help')));

    double height() => tester.getSize(find.byType(SettingsDisclosure)).height;
    final closed = height();
    await tester.tap(find.text('备份包含哪些内容？'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final mid = height();
    await tester.pumpAndSettle();
    final open = height();
    expect(open, greaterThan(closed + 40));
    expect(mid, greaterThan(closed));
    expect(mid, lessThan(open), reason: '中间帧必须是动画高度，不能瞬间跳变');

    // Reduced motion: the block is fully open on the next frame.
    await tester.tap(find.text('备份包含哪些内容？'));
    await tester.pumpAndSettle();
    expect(height(), closed);
    final store = AppThemeStyleStore()..value = AppThemeStyle.archive;
    addTearDown(store.dispose);
    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: MediaQuery(
          data: const MediaQueryData(
            disableAnimations: true,
            size: Size(400, 700),
          ),
          child: const LibraryBackupPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const ValueKey('backup-help')));
    final reducedClosed = height();
    await tester.tap(find.text('备份包含哪些内容？'));
    await tester.pump();
    expect(height(), greaterThan(reducedClosed + 40));
  });

  testWidgets('archive 披露块支持 Enter/Space 与 expanded 语义', (tester) async {
    mockBackupChannel(tester);
    await pumpStyled(
      tester,
      const LibraryBackupPage(),
      style: AppThemeStyle.archive,
      size: const Size(400, 700),
    );
    await scrollTo(tester, find.byKey(const ValueKey('backup-help')));

    await tester.tap(find.text('备份包含哪些内容？'));
    await tester.pumpAndSettle();
    expect(expandedFlag(tester), isTrue);

    // A pointer tap does not move focus; give the header focus like a keyboard
    // user tabbing to it, then activate with Enter / Space.
    Focus.of(tester.element(find.text('备份包含哪些内容？'))).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(expandedFlag(tester), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(expandedFlag(tester), isTrue);
    expect(find.textContaining('书架分组'), findsOneWidget);
  });

  testWidgets('经典关于页在窄屏大字号下不溢出且许可/赞赏可达', (tester) async {
    for (final width in [320.0, 360.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        final store = AppThemeStyleStore()..value = AppThemeStyle.classic;
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: TextScaler.linear(scale),
            ),
            child: AppUiHost(store: store, home: const AboutPage()),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: '${width}dp × $scale 不得有 RenderFlex 溢出',
        );
        expect(find.text(AboutPage.versionText), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('微信赞赏'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('开源许可'), findsOneWidget);
        expect(find.text('微信赞赏'), findsOneWidget);
        store.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    tester.view.reset();
  });

  testWidgets('1280 桌面宽度下经典关于页布局正常', (tester) async {
    final store = await pumpStyled(
      tester,
      const AboutPage(),
      size: const Size(1280, 900),
    );
    expect(find.byType(SettingsGroupCard), findsOneWidget);
    expect(find.text(AboutPage.versionText), findsOneWidget);
    expect(find.text('支持作者'), findsOneWidget);
    store.value = AppThemeStyle.archive;
    await tester.pumpAndSettle();
    expect(find.text('支持作者'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Uint8List _fanqieHistoryBytes() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'code': 0,
      'data': {
        'has_more': false,
        'next_offset': 0,
        'data_list': [
          for (var i = 0; i < 6; i++)
            {
              'book_id': '10$i',
              'book_type': 0,
              'book_name': '历史作品 $i',
              'read_timestamp_ms': 1000 + i,
            },
        ],
      },
    }),
  ),
);

/// In-memory preferences that can fail writes on demand.
class _ToggleFailStore extends InMemorySharedPreferencesStore {
  _ToggleFailStore(super.data) : super.withData();

  bool failWrites = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failWrites) {
      throw PlatformException(code: 'cannot-save-preference');
    }
    return super.setValue(valueType, key, value);
  }
}
