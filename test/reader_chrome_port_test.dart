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
    expect(find.byKey(const ValueKey('reader-chapter-seek')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-settings')), findsOneWidget);
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

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

  testWidgets('外观面板的步进器立即写入偏好', (tester) async {
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

    await tester.tap(find.byTooltip('增大字号'));
    await tester.pumpAndSettle();
    // 离散步进不经过 120ms 合并，点完即写入。
    expect(changes, hasLength(1));
    expect(changes.single.fontSize, 19);
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
