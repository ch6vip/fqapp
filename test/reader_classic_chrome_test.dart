import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_chapter_progress.dart';
import 'package:fqapp/widgets/reader/reader_chrome.dart';
import 'package:fqapp/widgets/reader/reader_classic_chrome.dart';
import 'package:fqapp/widgets/reader/reader_controls.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

/// Classic reader chrome (PR #292 task C) against the one live ReaderPage.
///
/// The two progress controls are covered separately on purpose: the classic
/// sheet's whole-book picker only loads a chapter on release, while the
/// chapter-internal row keeps the existing preview/commit lifecycle.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetAppUiTestDiagnostics();
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('经典主题顶部与底部外壳齐全，入口都接真实 callbacks', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    await _mountReader(tester, store);
    await _openControls(tester);

    // 顶部：实色顶栏、返回、书名 + 正在阅读章号、不会撑破的动作组。
    expect(
      find.byKey(const ValueKey('reader-classic-toolbar')),
      findsOneWidget,
    );
    expect(_isSolidTopBar(tester), isTrue);
    expect(find.byKey(const ValueKey('reader-back-entry')), findsOneWidget);
    expect(_textOf(tester, 'reader-header-book-title'), '经典外壳测试');
    expect(_textOf(tester, 'reader-classic-chapter-label'), '正在阅读 · 第 1 章');
    expect(find.byKey(const ValueKey('reader-cache')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-shelf-button')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-classic-collapse')),
      findsOneWidget,
    );

    // 底部：整块上圆角面板、整书选章滑条、章内进度、全部动作入口。
    expect(
      find.byKey(const ValueKey('reader-classic-controls')),
      findsOneWidget,
    );
    expect(
      _panelRadius(tester, 'reader-classic-controls-panel'),
      const BorderRadius.vertical(top: Radius.circular(22)),
    );
    expect(find.byKey(const ValueKey('reader-chapter-seek')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-classic-chapter-progress')),
      findsOneWidget,
    );
    expect(find.text('本章进度'), findsOneWidget);
    // 两条滑条语义不同：整书选章 vs 本章进度。
    final seekSemantics = tester.getSemantics(
      find.byKey(const ValueKey('reader-classic-chapter-seek-semantics')),
    );
    expect(seekSemantics.label, '整书选章');
    expect(seekSemantics.value, '第 1 章 / 共 4 章');
    for (final key in [
      'reader-catalogue-entry',
      'reader-bookmarks-entry',
      'reader-find-entry',
      'reader-operations-entry',
      'reader-night-entry',
      'reader-settings',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '$key 缺失');
      expect(_actionEnabled(tester, key), isTrue, reason: '$key 未接线');
    }
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('查找'), findsOneWidget);
    expect(find.text('书签'), findsOneWidget);
    expect(find.text('夜间'), findsOneWidget);

    // 听/看胶囊仍走当前 _buildReaderMenuPlayers。
    expect(find.byKey(const ValueKey('reader-listen-entry')), findsOneWidget);
    // 经典分支不画玻璃坞与边缘模糊。
    expect(find.byKey(const ValueKey('reader-liquid-dock')), findsNothing);
    expect(find.byType(ReaderEdgeBlur), findsNothing);
    expect(find.byType(ReaderControls), findsNothing);

    // 目录接到真实面板。
    await tester.tap(find.byKey(const ValueKey('reader-catalogue-entry')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-directory-scroll')),
      findsOneWidget,
    );
    Navigator.of(
      tester.element(find.byKey(const ValueKey('reader-directory-scroll'))),
    ).pop();
    await tester.pumpAndSettle();

    // 查找接到真实面板（需要已加载正文）。
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-find-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-find-field')), findsOneWidget);
    Navigator.of(
      tester.element(find.byKey(const ValueKey('reader-find-field'))),
    ).pop();
    await tester.pumpAndSettle();

    // 夜间接的是当前预设切换。
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-night-entry')));
    await tester.pumpAndSettle();
    expect(find.text('日间'), findsOneWidget);

    // 收起会真正隐藏两段外壳。
    await tester.tap(find.byKey(const ValueKey('reader-classic-collapse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-classic-toolbar')), findsNothing);
    expect(find.byKey(const ValueKey('reader-classic-controls')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('档案主题保持 Wenku8 顶栏与玻璃坞', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await _mountReader(tester, store);
    await _openControls(tester);

    expect(find.byKey(const ValueKey('reader-toolbar')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-liquid-dock')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-controls')), findsOneWidget);
    expect(find.byType(ReaderChapterProgress), findsOneWidget);
    expect(find.byType(ReaderEdgeBlur), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-classic-toolbar')), findsNothing);
    expect(find.byKey(const ValueKey('reader-classic-controls')), findsNothing);
    expect(find.byKey(const ValueKey('reader-chapter-seek')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切换 style 保留 ReaderPage State、章节与章内原文位置', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await _mountReader(tester, store);
    await _openControls(tester);

    // 先在档案主题里把章内进度推到中段，得到一个能证明 offset 的百分比。
    final archiveSlider = find.byKey(
      const ValueKey('reader-chrome-progress-slider'),
    );
    final rect = tester.getRect(archiveSlider);
    final gesture = await tester.startGesture(
      rect.centerLeft + const Offset(10, 0),
    );
    await tester.pump();
    await gesture.moveTo(rect.centerRight - const Offset(10, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final stateBefore = tester.state(find.byType(ReaderPage));
    final progressBefore = _textOf(tester, 'reader-progress');
    final viewportBefore = tester.getSize(
      find.byKey(const ValueKey('reader-page-surface')),
    );
    expect(_percentOf(progressBefore), greaterThan(0));

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();

    // 同一个 State、同一个章节、同一个正文位置、菜单仍然展开。
    expect(tester.state(find.byType(ReaderPage)), same(stateBefore));
    expect(_textOf(tester, 'reader-progress'), progressBefore);
    expect(
      tester.getSize(find.byKey(const ValueKey('reader-page-surface'))),
      viewportBefore,
    );
    expect(_textOf(tester, 'reader-classic-chapter-label'), '正在阅读 · 第 1 章');
    expect(
      find.byKey(const ValueKey('reader-classic-controls')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reader-liquid-dock')), findsNothing);

    // 切回档案主题同样不重开页面、不丢位置。
    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ReaderPage)), same(stateBefore));
    expect(_textOf(tester, 'reader-progress'), progressBefore);
    expect(find.byKey(const ValueKey('reader-liquid-dock')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-classic-controls')), findsNothing);

    // 收起状态跨主题也保持收起。
    await _closeControls(tester);
    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-classic-controls')), findsNothing);
    expect(find.byKey(const ValueKey('reader-classic-toolbar')), findsNothing);
    expect(tester.state(find.byType(ReaderPage)), same(stateBefore));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('整书选章滑条只在松手后跳章', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    final loads = <String>[];
    await _mountReader(tester, store, loads: loads);
    await _openControls(tester);

    expect(_textOf(tester, 'reader-classic-seek-position'), '1 / 4');
    final seek = find.byKey(const ValueKey('reader-chapter-seek'));
    final rect = tester.getRect(seek);
    final gesture = await tester.startGesture(
      rect.centerLeft + const Offset(10, 0),
    );
    await tester.pump();
    await gesture.moveTo(rect.centerRight - const Offset(6, 0));
    await tester.pump();

    // 拖动过程中只更新临时选中索引：预览标题/章号变了，章节本身没换。
    expect(_textOf(tester, 'reader-classic-seek-title'), '第四章');
    expect(_textOf(tester, 'reader-classic-seek-position'), '4 / 4');
    expect(_textOf(tester, 'reader-classic-chapter-label'), '正在阅读 · 第 1 章');
    expect(loads, isNot(contains('c4')));

    await gesture.up();
    await tester.pumpAndSettle();

    // 松手才走当前 _jumpToChapter。
    expect(loads, contains('c4'));
    expect(_textOf(tester, 'reader-classic-chapter-label'), '正在阅读 · 第 4 章');
    expect(_textOf(tester, 'reader-classic-seek-position'), '4 / 4');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('经典底栏的章内进度仍按 preview/commit 生效', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    final loads = <String>[];
    await _mountReader(tester, store, loads: loads);
    await _openControls(tester);

    final before = _textOf(tester, 'reader-progress');
    expect(_percentOf(before), 0);

    final slider = find.byKey(
      const ValueKey('reader-classic-chapter-progress'),
    );
    final rect = tester.getRect(slider);
    final gesture = await tester.startGesture(
      rect.centerLeft + const Offset(16, 0),
    );
    await tester.pump();
    await gesture.moveTo(rect.centerRight - const Offset(16, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    // 拖动章内进度不出章，底栏也不会被预览关掉（顶部按现有设计临时隐藏）。
    expect(_textOf(tester, 'reader-classic-seek-position'), '1 / 4');
    expect(
      find.byKey(const ValueKey('reader-classic-controls')),
      findsOneWidget,
    );

    await gesture.up();
    await tester.pumpAndSettle();

    final after = _textOf(tester, 'reader-progress');
    expect(_percentOf(after), greaterThan(_percentOf(before)));
    expect(_textOf(tester, 'reader-classic-chapter-label'), '正在阅读 · 第 1 章');
    expect(loads, isNot(contains('c4')));
    // 无障碍语义仍是「本章进度」，与档案主题同一套。
    expect(
      find.byKey(const ValueKey('reader-slider-semantics-本章进度')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(280, 640), const Size(320, 560)]) {
    testWidgets('窄屏大字号下经典外壳不溢出且入口可达 $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(
            Brightness.light,
            style: AppThemeStyle.classic,
          ),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(
              body: Column(
                children: [
                  ReaderClassicToolbar(
                    preset: ReaderThemePreset.light,
                    title: '很长很长的书名用来压住整行标题测试省略号',
                    chapterNumber: 12,
                    showCache: true,
                    showComments: true,
                    inShelf: true,
                    onBack: () => tapped++,
                    onCache: () => tapped++,
                    onComments: () => tapped++,
                    onShelf: () => tapped++,
                    onCollapse: () => tapped++,
                  ),
                  const Spacer(),
                  ReaderClassicControls(
                    preset: ReaderThemePreset.light,
                    chapterIndex: 11,
                    chapterCount: 345,
                    chapterTitleAt: (index) => '第 ${index + 1} 章 · 很长的章节名',
                    fraction: 0.42,
                    onPrevious: () => tapped++,
                    onNext: () => tapped++,
                    onSeekEnd: (_) => tapped++,
                    onPreview: (_) {},
                    onCommitted: (_) => tapped++,
                    onPreviewChanged: (_) {},
                    onDirectory: () => tapped++,
                    onBookmarks: () => tapped++,
                    onFind: () => tapped++,
                    onNight: () => tapped++,
                    onAppearance: () => tapped++,
                    onOperations: () => tapped++,
                    onAi: () => tapped++,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 顶部四个入口都在，且都能点（动作组在窄屏改为横向滚动，不丢按钮）。
      for (final key in [
        'reader-back-entry',
        'reader-cache',
        'reader-toolbar-chapter-comments',
        'reader-shelf-button',
        'reader-classic-collapse',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '$key 缺失');
        expect(_topActionEnabled(tester, key), isTrue, reason: '$key 未接线');
      }
      // 底栏七个入口都在，且都能点。
      for (final key in [
        'reader-catalogue-entry',
        'reader-bookmarks-entry',
        'reader-find-entry',
        'reader-operations-entry',
        'reader-ai',
        'reader-night-entry',
        'reader-settings',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '$key 缺失');
        expect(_actionEnabled(tester, key), isTrue, reason: '$key 未接线');
      }
      expect(find.byKey(const ValueKey('reader-chapter-seek')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-classic-chapter-progress')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('reader-back-entry')));
      await tester.pumpAndSettle();
      expect(tapped, greaterThan(0));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

Future<void> _mountReader(
  WidgetTester tester,
  AppThemeStyleStore store, {
  List<String>? loads,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppUiHost(
      store: store,
      home: ReaderPage(
        bookId: 'reader-classic-chrome',
        title: '经典外壳测试',
        chapters: [
          Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
          Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
          Chapter(itemId: 'c3', title: '第三章', volumeName: '正文'),
          Chapter(itemId: 'c4', title: '第四章', volumeName: '正文'),
        ],
        startIndex: 0,
        readerDevice: _Device(),
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        chapterLoader: (chapter) async {
          loads?.add(chapter.itemId);
          return List.generate(
            30,
            (index) => '第 $index 段用于经典外壳测试。',
          ).join('\n\n');
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

bool _controlsOpen() =>
    find
        .byKey(const ValueKey('reader-classic-toolbar'))
        .evaluate()
        .isNotEmpty ||
    find.byKey(const ValueKey('reader-toolbar')).evaluate().isNotEmpty;

Future<void> _openControls(WidgetTester tester) async {
  if (_controlsOpen()) return;
  await tester.tapAt(
    tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
  );
  await tester.pumpAndSettle();
}

Future<void> _closeControls(WidgetTester tester) async {
  if (!_controlsOpen()) return;
  await tester.tapAt(
    tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
  );
  await tester.pumpAndSettle();
}

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data ?? '';

bool _actionEnabled(WidgetTester tester, String key) =>
    tester
        .widget<TextButton>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(TextButton),
          ),
        )
        .onPressed !=
    null;

bool _topActionEnabled(WidgetTester tester, String key) {
  final finder = find.byKey(ValueKey(key));
  final widget = tester.widget(finder);
  final button = widget is IconButton
      ? widget
      : tester.widget<IconButton>(
          find.descendant(of: finder, matching: find.byType(IconButton)),
        );
  return button.onPressed != null;
}

double _percentOf(String text) =>
    double.parse(RegExp(r'([\d.]+)%').firstMatch(text)!.group(1)!);

bool _isSolidTopBar(WidgetTester tester) =>
    tester
        .widget<Material>(find.byKey(const ValueKey('reader-classic-toolbar')))
        .color ==
    ReaderThemePreset.light.panelColor;

BorderRadiusGeometry _panelRadius(WidgetTester tester, String key) =>
    tester.widget<Material>(find.byKey(ValueKey(key))).borderRadius!;

class _Device extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();

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
