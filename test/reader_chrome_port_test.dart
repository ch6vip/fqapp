import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_appearance_sheet.dart';
import 'package:fqapp/widgets/reader/reader_status_bar.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';

import 'support/fakes.dart';
import 'support/reader_settings_nav.dart';

/// Regression coverage for the Wenku8 reader-chrome port: glass dock, centered
/// toolbar, the compact progress capsule, discrete settings commits and the
/// status footer's narrow-width battery fallback.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('阅读菜单使用上游玻璃坞和进度胶囊', (tester) async {
    await _mountReader(tester);
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-liquid-dock')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-previous-chapter')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reader-next-chapter')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-chapter-seek')), findsNothing);
    expect(
      find.byKey(const ValueKey('reader-chrome-progress-slider')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reader-settings')), findsOneWidget);
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('操作'), findsOneWidget);
    expect(find.text('查找'), findsOneWidget);
    expect(find.text('夜读'), findsOneWidget);

    // 胶囊和坞按上游 DockLayout 的宽度收紧，不再铺满整栏。
    final capsule = tester.getSize(
      find.byKey(const ValueKey('reader-progress-capsule')),
    );
    expect(capsule.width, lessThanOrEqualTo(DockLayout.widthFor(5) - 32 + .5));
    final dock = tester.getSize(
      find.byKey(const ValueKey('reader-liquid-dock')),
    );
    expect(dock.width, lessThanOrEqualTo(DockLayout.widthFor(6) + .5));

    // 章内进度滑条的无障碍标签是「本章进度」，值是该章内的百分比。
    final sliderSemantics = tester.getSemantics(
      find.byKey(const ValueKey('reader-slider-semantics-本章进度')),
    );
    expect(sliderSemantics.label, '本章进度');
    expect(sliderSemantics.value, endsWith('%'));

    final back = tester.widget<GlassIconButton>(
      find.byKey(const ValueKey('reader-back-entry')),
    );
    expect(back.label, '返回书籍');
    expect(
      find.byKey(const ValueKey('reader-header-book-title')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('外观面板的步进器尾随合并写入偏好', (tester) async {
    final changes = <ReaderPreferences>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showReaderSettingsSheet(
                  context: context,
                  initialValue: const ReaderPreferences(),
                  onChanged: changes.add,
                  onPickFont: () async => null,
                  deviceAvailable: true,
                  systemBrightness: 0.45,
                  onBrightness: (_) {},
                  onBrightnessEnd: () {},
                  onFollowSystem: () {},
                  autoTurnActive: false,
                  onAutoTurn: () {},
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

    // 字号在「字体」分类里，是滑块而非步进器；拖动只预览，阅读页按
    // 120ms 尾随合并收到一次写入。
    await openReaderSettingsCategory(tester, 'font');
    final slider = find.byKey(const ValueKey('reader-font-size'));
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    // 面板自身立即更新，阅读页等到合并窗口结束才收到写入。
    expect(changes, isEmpty);
    await tester.pump(const Duration(milliseconds: 150));
    expect(changes, hasLength(1));
    expect(changes.single.fontSize, greaterThan(18));
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('墨水屏阅读页的顶栏与正文子层不启用实时玻璃', (tester) async {
    SharedPreferences.setMockInitialValues({
      'reader_theme_preset': ReaderThemePreset.eink.name,
    });
    await _mountReader(tester);
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
    );
    await tester.pumpAndSettle();

    // 顶栏和正文（段落选择条挂在这里）都必须落在轻量作用域内，否则 EPD
    // 上会走实时折射并留下灰阶残影。
    for (final key in ['reader-toolbar', 'reader-page-surface']) {
      final scope = PerformanceScope.of(
        tester.element(find.byKey(ValueKey(key))),
      );
      expect(scope.glass, isFalse, reason: '$key 仍启用实时玻璃');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('状态栏窄屏大字时保留时间与进度，不撑破布局', (tester) async {
    tester.view.physicalSize = const Size(280, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(280, 600),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: ReaderStatusBar(
              preset: ReaderThemePreset.light,
              status: ReaderDeviceStatus(
                time: DateTime(2026, 10, 30, 9, 5),
                battery: 64,
              ),
              progress: 0.42,
              chapterIndex: 0,
              chapterCount: 20,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('reader-clock')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-progress')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-battery')), findsNothing);
  });
}

Future<void> _mountReader(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderPage(
        bookId: 'reader-chrome-port',
        title: '阅读外壳测试',
        chapters: [
          Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
          Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
        ],
        startIndex: 0,
        readerDevice: _Device(),
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        chapterLoader: (_) async =>
            List.generate(30, (index) => '第 $index 段用于阅读外壳测试。').join('\n\n'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

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
