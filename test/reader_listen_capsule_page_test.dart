import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart' show AudioPage, AudioPlaybackScope;
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/reader_device.dart';

import 'support/fakes.dart';

/// 阅读页听书胶囊的整页行为：跟菜单一起显隐、不压控制条、未听书时的
/// 播放/关闭语义。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ListeningSession.instance.clear();
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  tearDown(() {
    ListeningSession.instance.clear();
    AudioPlaybackScope.startListeningOverride = null;
  });

  testWidgets('菜单收起时没有胶囊，呼出后出现且不压住控制条', (tester) async {
    await _mount(tester);
    expect(_capsule, findsNothing, reason: '菜单没开时不该占位');

    await _openMenu(tester);
    expect(_capsule, findsOneWidget);

    final capsule = tester.getRect(_capsule);
    final controls = tester.getRect(
      find.byKey(const ValueKey('reader-controls')),
    );
    expect(
      capsule.bottom,
      lessThanOrEqualTo(controls.top),
      reason: '胶囊在控制条上方，不能重叠',
    );
    expect(capsule.left, greaterThanOrEqualTo(0));
    expect(capsule.right, lessThanOrEqualTo(430));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未听书时点播放：从本页起播，菜单保持展开', (tester) async {
    AudioPage? started;
    AudioPlaybackScope.startListeningOverride = (context, request) async {
      started = request;
      return true;
    };
    await _mount(tester);
    await _openMenu(tester);

    expect(find.text('听'), findsOneWidget, reason: '未听书封面位显示「听」');
    await tester.tap(find.byKey(const ValueKey('reader-listen-toggle')));
    await tester.pumpAndSettle();

    expect(started, isNotNull);
    expect(started!.bookId, 'capsule-test');
    expect(
      find.byKey(const ValueKey('reader-controls')),
      findsOneWidget,
      reason: '从胶囊起播不能被收起的菜单吞掉',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未听书时点 × 收起菜单', (tester) async {
    await _mount(tester);
    await _openMenu(tester);
    expect(find.byKey(const ValueKey('reader-controls')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-listen-close')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-controls')), findsNothing);
    expect(_capsule, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final _capsule = find.byKey(const ValueKey('reader-listen-capsule'));
final _surface = find.byKey(const ValueKey('reader-page-surface'));

Future<void> _mount(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderPage(
        bookId: 'capsule-test',
        title: '测试书籍',
        chapters: [Chapter(itemId: 'c1', title: '第一章', volumeName: '正文')],
        startIndex: 0,
        readerStore: MemoryReaderStore(),
        chapterCache: MemoryChapterCache(),
        chapterLoader: (_) async => parseChapterContent(
          '<header><div class="tt-title">第一章</div></header><article>'
          '<p idx="0">第一段正文，用来撑开阅读页。</p>'
          '<p idx="1">第二段正文，菜单点开之后胶囊要出现在这里。</p>'
          '</article>',
        ).toCacheText(),
        readerDevice: _NullDevice(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tapAt(tester.getRect(_surface).center);
  await tester.pumpAndSettle();
}

class _NullDevice extends ReaderDevice {
  @override
  Stream<ReaderDeviceStatus> get changes => const Stream.empty();
  @override
  Future<ReaderDeviceStatus?> start({
    required bool followSystem,
    required double brightness,
  }) async => ReaderDeviceStatus(
    time: DateTime(2026, 9, 10, 21, 16),
    battery: 64,
    systemBrightness: .45,
  );
  @override
  Future<void> suspend() async {}
  @override
  Future<void> close() async {}
}
