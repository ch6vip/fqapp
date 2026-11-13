import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/chapter_ideas.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart' show AudioPlaybackScope;
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/ai_reading/ai_settings.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/playlet_share.dart';
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/reader/reader_chapter_progress.dart';
import 'package:fqapp/widgets/reader/reader_chrome.dart';
import 'package:fqapp/widgets/reader/reader_classic_chrome.dart';
import 'package:fqapp/widgets/reader/reader_classic_more_sheet.dart';
import 'package:fqapp/widgets/reader/reader_controls.dart';
import 'package:fqapp/widgets/reader/reader_listen_button.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';
import 'package:fqapp/widgets/reader/reader_toast.dart';
import 'package:fqapp/widgets/reader/reader_video_button.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

/// Classic reader chrome (PR #292 task C) against the one live ReaderPage.
///
/// Classic scrubbing previews in a transient overlay and commits on release.
/// Archive chapter-local progress and source anchors survive style switches.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const ttsChannel = MethodChannel('fqapp/system_tts');
  const ttsEvents = MethodChannel('fqapp/system_tts_events');
  const playerChannel = MethodChannel('fqapp/native_player');
  late List<MethodCall> nativeCalls;
  late Directory hiveDirectory;

  setUpAll(() {
    // `ApiClient.instance` must be built inside the mocked HTTP zone: its
    // rust-fallback transport captures the ambient `http.Client` when built.
    http.runWithClient(() => ApiClient.instance, () => MockClient(_apiHandler));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    resetAppUiTestDiagnostics();
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
    nativeCalls = [];
    messenger.setMockMethodCallHandler(ttsEvents, (_) async => null);
    messenger.setMockMethodCallHandler(playerChannel, (_) async => null);
    messenger.setMockMethodCallHandler(ttsChannel, (call) async {
      nativeCalls.add(call);
      return call.method == 'initialize' ? 4000 : null;
    });
    // The shelf entry needs a real (isolated) box; every test gets its own.
    hiveDirectory = await Directory.systemTemp.createTemp('fqapp-classic-');
    Hive.init(hiveDirectory.path);
    await ShelfStore.instance.init();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(ttsChannel, null);
    messenger.setMockMethodCallHandler(ttsEvents, null);
    messenger.setMockMethodCallHandler(playerChannel, null);
    ListeningSession.instance.clear();
    debugDefaultTargetPlatformOverride = null;
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await hiveDirectory.delete(recursive: true);
    } catch (_) {
      // Temp dir cleanup is best effort.
    }
  });

  testWidgets('经典主题顶部与单行动作齐全，入口都接真实 callbacks', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _mountReader(tester, store);
      await _openControls(tester);

      // 顶部显示入架状态，标题和章号不再常驻。
      expect(
        find.byKey(const ValueKey('reader-classic-toolbar')),
        findsOneWidget,
      );
      expect(_isSolidTopBar(tester), isTrue);
      for (final key in [
        'reader-back-entry',
        'reader-cache',
        'reader-shelf-button',
        'reader-share',
        'reader-classic-more',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(find.text('加入书架'), findsOneWidget);
      for (final key in [
        'reader-header-book-title',
        'reader-classic-chapter-label',
        'reader-classic-chapter-progress',
        'reader-classic-seek-title',
        'reader-classic-seek-position',
        'reader-classic-seek-preview',
        'reader-find-entry',
        'reader-bookmarks-entry',
        'reader-operations-entry',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(
        find.byKey(const ValueKey('reader-classic-controls')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reader-chapter-seek')), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('本章进度'), findsNothing);
      expect(find.text('上一章'), findsOneWidget);
      expect(find.text('下一章'), findsOneWidget);
      final seekSemantics = tester.getSemantics(
        find.byKey(const ValueKey('reader-classic-chapter-seek-semantics')),
      );
      expect(seekSemantics.label, '整书选章');
      expect(seekSemantics.value, '第 1 章 / 共 4 章');
      final actionTops = <double>{};
      for (final key in [
        'reader-catalogue-entry',
        'reader-night-entry',
        'reader-settings',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
        expect(_actionEnabled(tester, key), isTrue);
        actionTops.add(_topOf(tester, key));
      }
      expect(actionTops, hasLength(1), reason: '目录/夜间/设置同排');
      expect(
        find.byKey(const ValueKey('reader-classic-action-row')),
        findsOneWidget,
      );
      expect(find.text('目录'), findsOneWidget);
      expect(find.text('夜间'), findsOneWidget);
      expect(find.text('查找'), findsNothing);

      // 听/看胶囊仍走当前 _buildReaderMenuPlayers。
      expect(find.byKey(const ValueKey('reader-listen-entry')), findsOneWidget);
      // 经典分支不画玻璃坞与边缘模糊。
      expect(find.byKey(const ValueKey('reader-liquid-dock')), findsNothing);
      expect(find.byType(ReaderEdgeBlur), findsNothing);
      expect(find.byType(ReaderControls), findsNothing);
      // 生产 scope 全程在场，本次没有任何主题回退读取。
      expect(AppUiScope.debugFallbackReads, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('经典更多底部面板显示书籍信息和四个动作，关闭后保留控件', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    await _mountReader(tester, store);
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-classic-more')));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('reader-classic-more-sheet'));
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text('经典外壳测试')),
      findsOneWidget,
    );
    for (final entry in const {
      'classic-reader-details': '书籍详情',
      'classic-reader-add-bookmark': '添加书签',
      'classic-reader-bookmarks': '书签管理',
      'classic-reader-full-search': '全文搜索',
    }.entries) {
      final button = find.byKey(ValueKey(entry.key));
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      expect(
        find.descendant(of: sheet, matching: find.text(entry.value)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: sheet, matching: find.byType(TextButton)),
      findsNWidgets(4),
    );
    for (final label in ['评分', '加入书架', '缓存', '本章评论']) {
      expect(
        find.descendant(of: sheet, matching: find.text(label)),
        findsNothing,
      );
    }
    expect(tester.getRect(sheet).bottom, greaterThan(700));
    await tester.tapAt(const Offset(24, 160));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(
      find.byKey(const ValueKey('reader-classic-toolbar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-classic-controls-panel')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('更多面板保留封面与作者，动作返回值和禁用状态正确', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    String? result;
    var ready = true;
    await tester.pumpWidget(
      AppUiHost(
        store: store,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<String>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => ReaderClassicMoreSheet(
                    title: '封面和作者测试',
                    author: '测试作者',
                    cover: '',
                    preset: ReaderThemePreset.light,
                    canBookmark: ready,
                    canSearch: ready,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    for (final entry in const {
      'classic-reader-details': 'details',
      'classic-reader-add-bookmark': 'bookmark',
      'classic-reader-bookmarks': 'bookmarks',
      'classic-reader-full-search': 'search',
    }.entries) {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('封面和作者测试'), findsOneWidget);
      expect(find.text('测试作者'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ReaderClassicMoreSheet),
          matching: find.byType(ClipRRect),
        ),
        findsOneWidget,
        reason: '无封面时仍保留封面占位',
      );
      expect(find.textContaining('评分'), findsNothing);
      await tester.tap(find.byKey(ValueKey(entry.key)));
      await tester.pumpAndSettle();
      expect(result, entry.value);
    }
    ready = false;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    for (final key in [
      'classic-reader-add-bookmark',
      'classic-reader-full-search',
    ]) {
      expect(
        tester.widget<TextButton>(find.byKey(ValueKey(key))).onPressed,
        isNull,
      );
    }
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('classic-reader-details')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('经典全文搜索选择结果才跨章并高亮精确原文位置', (tester) async {
    const query = '唯一跨章命中';
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    final history = _CountingStore();
    final cache = MemoryChapterCache();
    final loads = <String>[];
    await _mountReader(
      tester,
      store,
      bookId: 'classic-full-search-navigation',
      readerStore: history,
      chapterCache: cache,
      loads: loads,
      preferences: const {'reader_page_mode': 'paged'},
      chapterLoader: (chapter) async => List.generate(
        40,
        (index) => chapter.itemId == 'c3' && index == 27
            ? '山路转弯，$query，故事仍在继续。'
            : '${chapter.itemId} 第 $index 段，山风吹过窗台，书页在阳光下缓缓翻开。',
      ).join('\n\n'),
    );
    await _openControls(tester);
    final initialPager = tester.widget<ReaderPagedView>(
      find.byType(ReaderPagedView),
    );
    final initialLayout = initialPager.layout;
    final initialPage = initialPager.pageIndex;
    final state = tester.state(find.byType(ReaderPage));
    final writesBefore = history.writes;
    final historyBefore = history.entry == null
        ? null
        : Map<String, dynamic>.of(history.entry!);
    final loadsBefore = List<String>.of(loads);

    await tester.tap(find.byKey(const ValueKey('reader-classic-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('classic-reader-full-search')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('reader-full-search-field'));
    expect(field, findsOneWidget);
    expect(loads, loadsBefore, reason: '仅打开搜索不读取其他章节');
    expect(history.writes, writesBefore);
    expect(history.entry, historyBefore);

    await tester.enterText(field, query);
    await tester.pump(const Duration(milliseconds: 200));
    expect(loads, loadsBefore, reason: '输入防抖期间不启动章节读取');
    expect(history.writes, writesBefore);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    // The final uncached chapter waits for the 300ms network pacing slot.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final result = find.byKey(const ValueKey('reader-full-search-result-2-0'));
    expect(result, findsOneWidget);
    expect(loads.toSet(), containsAll(['c1', 'c2', 'c3', 'c4']));
    expect(
      cache.content['classic-full-search-navigation']?.keys,
      containsAll(['c1', 'c2', 'c3', 'c4']),
    );
    final unchanged = tester.widget<ReaderPagedView>(
      find.byType(ReaderPagedView),
    );
    expect(unchanged.layout, same(initialLayout));
    expect(unchanged.pageIndex, initialPage);
    expect(unchanged.selection, isNull);
    expect(tester.state(find.byType(ReaderPage)), same(state));
    expect(history.writes, writesBefore, reason: '搜索缓存不写阅读历史');
    expect(history.entry, historyBefore);
    final cachedLoads = List<String>.of(loads);

    await tester.ensureVisible(result);
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    final landed = tester.widget<ReaderPagedView>(find.byType(ReaderPagedView));
    final block = landed.layout.blocks.singleWhere(
      (block) => !block.isTitle && !block.isImage && block.text.contains(query),
    );
    final start = block.start + block.text.indexOf(query);
    final expectedPage = landed.layout.pageForOffset(start);
    expect(expectedPage, greaterThan(0), reason: '结果位于目标章正文深处');
    expect(landed.pageIndex, expectedPage);
    expect(landed.selection?.start, start);
    expect(landed.selection?.end, start + query.length);
    expect(history.entry?['chapterId'], 'c3');
    expect(history.writes, greaterThan(writesBefore));
    expect(loads, cachedLoads, reason: '选择已缓存结果无需重复读正文');
    await _openControls(tester);
    expect(
      tester
          .widget<ReaderClassicControls>(find.byType(ReaderClassicControls))
          .chapterIndex,
      2,
    );
    expect(tester.state(find.byType(ReaderPage)), same(state));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('经典分享把书名和链接交给系统分享桥，并提示无法启动', (tester) async {
    final previous = SharePlusLite.handler;
    addTearDown(() => SharePlusLite.handler = previous);
    final shares = <({String title, String text})>[];
    SharePlusLite.handler = ({required title, required text}) async {
      shares.add((title: title, text: text));
      return true;
    };
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    await _mountReader(tester, store);
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-share')));
    await tester.pumpAndSettle();
    expect(shares, [
      (
        title: '经典外壳测试',
        text: '经典外壳测试\nhttps://fanqienovel.com/page/reader-classic-chrome',
      ),
    ]);
    expect(find.text('暂时无法打开系统分享面板'), findsNothing);
    SharePlusLite.handler = ({required title, required text}) async => false;
    await tester.tap(find.byKey(const ValueKey('reader-share')));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法打开系统分享面板'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('经典短提示为屏幕顶部居中的紧凑灰底白字胶囊', (tester) async {
    final previous = SharePlusLite.handler;
    addTearDown(() => SharePlusLite.handler = previous);
    SharePlusLite.handler = ({required title, required text}) async => false;
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    await _mountReader(tester, store);
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-share')));
    await tester.pumpAndSettle();
    _expectClassicToast(tester, '暂时无法打开系统分享面板');
    expect(find.byType(SnackBar), findsNothing);
    await _closeControls(tester);
    expect(find.byKey(const ValueKey('reader-toast')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('经典提示收起菜单时消失', (tester) async {
    final previous = SharePlusLite.handler;
    addTearDown(() => SharePlusLite.handler = previous);
    SharePlusLite.handler = ({required title, required text}) async => false;
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    await _mountReader(tester, store);
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-share')));
    await tester.pumpAndSettle();
    await _closeControls(tester);
    expect(find.text('暂时无法打开系统分享面板'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('经典入架提示替换旧提示并使用相同的顶部居中胶囊', (tester) async {
    final previous = SharePlusLite.handler;
    addTearDown(() => SharePlusLite.handler = previous);
    SharePlusLite.handler = ({required title, required text}) async => false;
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    await _mountReader(tester, store);
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-share')));
    await tester.pumpAndSettle();
    _expectClassicToast(tester, '暂时无法打开系统分享面板');
    await tester.tap(find.byKey(const ValueKey('reader-shelf-button')));
    await _settleShelfWrite(tester, '已加入书架');
    expect(find.text('暂时无法打开系统分享面板'), findsNothing);
    _expectClassicToast(tester, '已加入书架');
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('重复短提示重置自动消失时间且不排队', (tester) async {
    final previous = SharePlusLite.handler;
    addTearDown(() => SharePlusLite.handler = previous);
    SharePlusLite.handler = ({required title, required text}) async => false;
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    await _mountReader(tester, store);
    await _openControls(tester);
    await tester.tap(find.byKey(const ValueKey('reader-share')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1100));
    _expectClassicToast(tester, '暂时无法打开系统分享面板');
    await tester.tap(find.byKey(const ValueKey('reader-share')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1100));
    _expectClassicToast(tester, '暂时无法打开系统分享面板');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-toast')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('暂时无法打开系统分享面板'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('顶部胶囊在窄屏与两倍字号下换行且保持居中', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const message = '书签删除失败，请重试';
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Stack(children: [ReaderToast(message: message)]),
          ),
        ),
      ),
    );
    final toast = tester.getRect(find.byKey(const ValueKey('reader-toast')));
    final text = tester.getRect(find.text(message));
    expect(toast.top, closeTo(568 * .15, .5));
    expect(toast.center.dx, closeTo(160, .5));
    expect(toast.left, greaterThanOrEqualTo(24));
    expect(toast.right, lessThanOrEqualTo(296));
    expect(text.height, greaterThan(40), reason: '两倍字号的长提示需要换行');
    expect(toast.contains(text.topLeft), isTrue);
    expect(toast.contains(text.bottomRight), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final change in ['弹层', '风格', '窗口尺寸']) {
    testWidgets('经典短提示在$change变化后消失', (tester) async {
      final previous = SharePlusLite.handler;
      addTearDown(() => SharePlusLite.handler = previous);
      SharePlusLite.handler = ({required title, required text}) async => false;
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _mountReader(tester, store);
      await _openControls(tester);
      await tester.tap(find.byKey(const ValueKey('reader-share')));
      await tester.pumpAndSettle();
      expect(find.text('暂时无法打开系统分享面板'), findsOneWidget);
      switch (change) {
        case '弹层':
          await tester.tap(find.byKey(const ValueKey('reader-classic-more')));
        case '风格':
          await store.select(AppThemeStyle.archive);
        case '窗口尺寸':
          tester.view.physicalSize = const Size(844, 390);
      }
      await tester.pumpAndSettle();
      expect(find.text('暂时无法打开系统分享面板'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('新书签提示仍在顶部，短提示及菜单收起不影响长驻操作提示', (tester) async {
    final previous = SharePlusLite.handler;
    addTearDown(() => SharePlusLite.handler = previous);
    SharePlusLite.handler = ({required title, required text}) async => false;
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    final bookmarks = _Bookmarks();
    await _mountReader(tester, store, bookmarkStore: bookmarks);
    await _openControls(tester);
    final messenger = ScaffoldMessenger.of(
      tester.element(find.byType(ReaderPage)),
    );
    messenger.showSnackBar(
      SnackBar(
        content: const Text('长驻操作提示'),
        duration: const Duration(days: 1),
        action: SnackBarAction(label: '操作', onPressed: () {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-share')));
    await tester.pumpAndSettle();
    _expectClassicToast(tester, '暂时无法打开系统分享面板');
    expect(find.text('长驻操作提示'), findsOneWidget);
    await _closeControls(tester);
    expect(find.byKey(const ValueKey('reader-toast')), findsNothing);
    expect(find.text('长驻操作提示'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('reader-page-surface')),
      const Offset(0, 200),
    );
    await tester.pumpAndSettle();
    expect(find.text('已添加书签'), findsOneWidget);
    _expectClassicToast(tester, '已添加书签');
    expect(find.text('长驻操作提示'), findsOneWidget);
    messenger.removeCurrentSnackBar();
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
    expect(find.byType(ReaderClassicToolbar), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切换 style 保留 State、正文 pager/layout 与章内原文位置', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final loads = <String>[];
    await _mountReader(tester, store, loads: loads);
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
    final pagerBefore = tester.state(find.byType(ReaderPagedView));
    final layoutBefore = tester
        .widget<ReaderPagedView>(find.byType(ReaderPagedView))
        .layout;
    final progressBefore = _textOf(tester, 'reader-progress');
    final viewportBefore = tester.getSize(
      find.byKey(const ValueKey('reader-page-surface')),
    );
    final loadsBefore = List<String>.of(loads);
    expect(_percentOf(progressBefore), greaterThan(0));

    await store.select(AppThemeStyle.classic);
    await tester.pumpAndSettle();

    // 同一个 ReaderPage State、同一个 pager State、同一份排版；正文位置与
    // 菜单状态都不变，也没有因为换壳重读章节。
    expect(tester.state(find.byType(ReaderPage)), same(stateBefore));
    expect(tester.state(find.byType(ReaderPagedView)), same(pagerBefore));
    expect(
      tester.widget<ReaderPagedView>(find.byType(ReaderPagedView)).layout,
      same(layoutBefore),
    );
    expect(loads, loadsBefore);
    expect(_textOf(tester, 'reader-progress'), progressBefore);
    expect(
      tester.getSize(find.byKey(const ValueKey('reader-page-surface'))),
      viewportBefore,
    );
    expect(
      tester
          .widget<ReaderClassicControls>(find.byType(ReaderClassicControls))
          .chapterIndex,
      0,
    );
    expect(
      find.byKey(const ValueKey('reader-classic-controls')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reader-liquid-dock')), findsNothing);

    // 切回档案主题同样不重开页面、不丢位置。
    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ReaderPage)), same(stateBefore));
    expect(tester.state(find.byType(ReaderPagedView)), same(pagerBefore));
    expect(loads, loadsBefore);
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

  testWidgets('整书选章气泡只在拖动时显示，松手才跳章和写盘', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      final loads = <String>[];
      final history = _CountingStore();
      await _mountReader(tester, store, loads: loads, readerStore: history);
      await _openControls(tester);
      final writesBefore = history.writes;
      final progressBefore = _textOf(tester, 'reader-progress');
      final loadsBefore = List<String>.of(loads);
      final bubble = find.byKey(const ValueKey('reader-classic-seek-preview'));
      expect(bubble, findsNothing);
      final rect = tester.getRect(
        find.byKey(const ValueKey('reader-chapter-seek')),
      );
      final gesture = await tester.startGesture(
        rect.centerLeft + const Offset(10, 0),
      );
      await tester.pump();
      await gesture.moveTo(rect.center);
      await tester.pump();
      expect(bubble, findsOneWidget);
      await gesture.moveTo(rect.centerRight - const Offset(6, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        find.descendant(of: bubble, matching: find.text('100%\n第四章')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ReaderClassicControls>(find.byType(ReaderClassicControls))
            .chapterIndex,
        0,
      );
      expect(loads, loadsBefore);
      expect(history.writes, writesBefore, reason: '拖动中不写进度');
      expect(_textOf(tester, 'reader-progress'), progressBefore);
      expect(
        tester
            .getSemantics(
              find.byKey(
                const ValueKey('reader-classic-chapter-seek-semantics'),
              ),
            )
            .value,
        '第 4 章 / 共 4 章',
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(bubble, findsNothing);
      expect(loads.where((id) => id == 'c4'), hasLength(1));
      expect(
        tester
            .widget<ReaderClassicControls>(find.byType(ReaderClassicControls))
            .chapterIndex,
        3,
      );
      expect(history.writes, greaterThan(writesBefore));
      expect(history.entry?['chapterId'], 'c4');
      for (final key in [
        'reader-classic-seek-position',
        'reader-classic-seek-title',
        'reader-classic-chapter-label',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('整书选章的无障碍增减直接跳章，首章禁用上一章', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      final loads = <String>[];
      await _mountReader(tester, store, loads: loads);
      await _openControls(tester);
      final seek = find.byKey(
        const ValueKey('reader-classic-chapter-seek-semantics'),
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('reader-classic-previous-chapter')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.getSemantics(seek),
        matchesSemantics(
          label: '整书选章',
          value: '第 1 章 / 共 4 章',
          increasedValue: '第 2 章 / 共 4 章',
          decreasedValue: '第 1 章 / 共 4 章',
          isSlider: true,
          hasEnabledState: true,
          isEnabled: true,
          hasIncreaseAction: true,
        ),
      );
      tester.widget<Semantics>(seek).properties.onIncrease!();
      await tester.pumpAndSettle();
      expect(loads.where((id) => id == 'c2'), hasLength(1));
      expect(
        tester
            .widget<ReaderClassicControls>(find.byType(ReaderClassicControls))
            .chapterIndex,
        1,
      );
      expect(tester.getSemantics(seek).value, '第 2 章 / 共 4 章');
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('reader-classic-previous-chapter')),
            )
            .onPressed,
        isNotNull,
      );
      tester.widget<Semantics>(seek).properties.onDecrease!();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReaderClassicControls>(find.byType(ReaderClassicControls))
            .chapterIndex,
        0,
      );
      expect(
        find.byKey(const ValueKey('reader-classic-seek-preview')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('整书选章拖动中切风格：移除气泡且不提交目标章', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    final loads = <String>[];
    await _mountReader(tester, store, loads: loads);
    await _openControls(tester);

    final rect = tester.getRect(
      find.byKey(const ValueKey('reader-chapter-seek')),
    );
    final gesture = await tester.startGesture(
      rect.centerLeft + const Offset(16, 0),
    );
    await tester.pump();
    await gesture.moveTo(rect.centerRight - const Offset(16, 0));
    await tester.pump();

    await store.select(AppThemeStyle.archive);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('reader-toolbar')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-liquid-dock')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-classic-controls')), findsNothing);
    expect(
      find.byKey(const ValueKey('reader-classic-seek-preview')),
      findsNothing,
    );
    // 停在同一章：档案坞拿到的章节号仍是 0，也没有加载更远的章节。
    expect(
      tester.widget<ReaderControls>(find.byType(ReaderControls)).chapterIndex,
      0,
    );
    expect(loads.where((id) => id == 'c3' || id == 'c4'), isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('经典底板随 _chrome 收起，终态隐藏且正文 viewport 不变', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    await _mountReader(tester, store);
    await _openControls(tester);

    final panel = find.byKey(const ValueKey('reader-classic-controls-panel'));
    final toolbar = find.byKey(const ValueKey('reader-classic-toolbar'));
    final viewport = find.byKey(const ValueKey('reader-page-surface'));
    final viewportSize = tester.getSize(viewport);
    final panelTop = tester.getTopLeft(panel).dy;
    final panelHeight = tester.getSize(panel).height;
    final toolbarTop = tester.getTopLeft(toolbar).dy;

    // 顶栏已不再放独立的“收起”按钮：点正文中央仍走同一条 _toggleControls。
    await tester.tapAt(
      tester.getRect(find.byKey(const ValueKey('reader-page-surface'))).center,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    // 中间帧：底栏向下位移、顶栏向上位移，底板自身尺寸不变。
    expect(
      tester.getTopLeft(panel).dy,
      greaterThan(panelTop),
      reason: '经典底板必须跟着 _chrome 下滑，不能停在原位',
    );
    expect(tester.getSize(panel).height, panelHeight);
    expect(
      tester.getTopLeft(toolbar).dy,
      lessThan(toolbarTop),
      reason: '顶栏与底板应共用同一条收起动画',
    );
    expect(tester.getSize(viewport), viewportSize);

    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(toolbar, findsNothing);
    expect(tester.getSize(viewport), viewportSize);

    // 再次展开也走同一条动画，最后回到展开时的位置。
    await _openControls(tester);
    expect(tester.getTopLeft(panel).dy, panelTop);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final config in ['减少动态', '墨水屏']) {
    testWidgets('$config 时经典底板直接到终态', (tester) async {
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.select(AppThemeStyle.classic);
      await _mountReader(
        tester,
        store,
        preferences: config == '墨水屏'
            ? const {'reader_theme_preset': 'eink'}
            : const {},
        disableAnimations: config == '减少动态',
      );
      await _openControls(tester);

      final panel = find.byKey(const ValueKey('reader-classic-controls-panel'));
      final panelTop = tester.getTopLeft(panel).dy;

      await tester.tapAt(
        tester
            .getRect(find.byKey(const ValueKey('reader-page-surface')))
            .center,
      );
      await tester.pump();
      // 一帧就消失，没有中间位移。
      expect(panel, findsNothing);
      expect(
        find.byKey(const ValueKey('reader-classic-toolbar')),
        findsNothing,
      );

      await _openControls(tester);
      expect(
        find.byKey(const ValueKey('reader-classic-controls')),
        findsOneWidget,
      );
      expect(tester.getTopLeft(panel).dy, panelTop);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('真实入口：缓存/章评/书签/设置/AI/入架', (tester) async {
    const bookId = 'reader-classic-entries';
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    final bookmarks = _Bookmarks();
    await AiSettingsStore.instance.setBookOverride(bookId, 'enabled', true);
    addTearDown(
      () => AiSettingsStore.instance.clearBookOverride(bookId, 'enabled'),
    );
    await _mountReader(
      tester,
      store,
      bookId: bookId,
      bookmarkStore: bookmarks,
      ideasLoader: (_) async => _ideas(),
      commentResolver: (_, _, _) async => const BookCommentPage(
        comments: [BookComment(id: 'c1', text: '第一段评论')],
      ),
    );
    await _openControls(tester);
    expect(find.byKey(const ValueKey('reader-ai')), findsOneWidget);

    Future<void> openAction(String key) async {
      await _openControls(tester);
      final finder = find.byKey(ValueKey(key));
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<void> closePanel(String key) async {
      Navigator.of(tester.element(find.byKey(ValueKey(key)))).pop();
      await tester.pumpAndSettle();
    }

    // 缓存：真实缓存面板。
    await openAction('reader-cache');
    expect(find.byKey(const ValueKey('chapter-cache-scroll')), findsOneWidget);
    await closePanel('chapter-cache-scroll');

    // 章评：真实段评数据打开段评面板。
    await openAction('reader-toolbar-chapter-comments');
    expect(find.byKey(const Key('reader-ideas-title')), findsOneWidget);
    expect(find.text('第一段评论'), findsOneWidget);
    Navigator.of(
      tester.element(find.byKey(const Key('reader-ideas-title'))),
    ).pop();
    await tester.pumpAndSettle();

    // 设置：经典一屏面板（不是档案分类网格）；操作入口已移除，操作项仍从
    // 更多设置里的“操作”分类进入。
    await openAction('reader-settings');
    expect(
      find.byKey(const ValueKey('reader-appearance-scroll')),
      findsOneWidget,
    );
    expect(find.text('阅读设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-settings-marks')), findsNothing);
    expect(
      find.byKey(const ValueKey('reader-settings-category-grid')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('reader-more-appearance')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-more-settings-scroll')),
      findsOneWidget,
    );
    expect(find.text('点击区域'), findsOneWidget);
    expect(find.text('音量键翻页'), findsOneWidget);
    Navigator.of(tester.element(find.text('点击区域'))).pop();
    await tester.pumpAndSettle();
    await closePanel('reader-appearance-scroll');

    // 更多 → 添加书签直接写入当前章，不打开管理面板。
    await openAction('reader-classic-more');
    await tester.tap(find.byKey(const ValueKey('classic-reader-add-bookmark')));
    await tester.pumpAndSettle();
    expect(bookmarks.entries, hasLength(1));
    expect(bookmarks.entries.single.chapterId, 'c1');
    expect(bookmarks.entries.single.text, isNotEmpty);
    expect(find.byKey(const ValueKey('reader-bookmarks-scroll')), findsNothing);
    expect(
      find.byKey(const ValueKey('reader-classic-more-sheet')),
      findsNothing,
    );
    expect(find.text('已添加书签'), findsOneWidget);

    // 更多中的书签管理入口进入共享管理面板。
    await openAction('reader-classic-more');
    final marksEntry = find.byKey(const ValueKey('classic-reader-bookmarks'));
    await tester.ensureVisible(marksEntry);
    await tester.pumpAndSettle();
    await tester.tap(marksEntry);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-bookmarks-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('reader-bookmark-${bookmarks.entries.single.key}')),
      findsOneWidget,
    );
    await closePanel('reader-bookmarks-scroll');

    // AI：真实面板（本章已启用 AI）。
    await openAction('reader-ai');
    expect(find.widgetWithText(SwitchListTile, '本次看原文'), findsOneWidget);
    Navigator.of(
      tester.element(find.widgetWithText(SwitchListTile, '本次看原文')),
    ).pop();
    await tester.pumpAndSettle();

    // 入架：真实书架写入 + 提示 + 顶栏状态。
    await openAction('reader-shelf-button');
    await _settleShelfWrite(tester, '已加入书架');
    expect(ShelfStore.instance.contains('book', bookId), isTrue);
    expect(find.text('已加入书架'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('reader-shelf-button')),
        matching: find.text('已加书架'),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('真实入口：听书走系统朗读，看剧走真实启动路径', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    // 非本地书 + 系统朗读偏好：入口走当前 TTS 起播。
    await _mountReader(
      tester,
      store,
      audioScope: true,
      preferences: const {'audio_listen_engine': 'system'},
    );
    AudioPreferences.instance.listenEngine.value = ListenEngine.system;
    await tester.pumpAndSettle();
    await _openControls(tester);

    // Tapping the keyed Padding would miss the 42dp circle it centres.
    final listen = find.byType(ReaderListenButton).hitTestable();
    expect(listen, findsOneWidget);
    await tester.tap(listen);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      nativeCalls.map((call) => call.method),
      contains('speak'),
      reason: '听书入口必须把真实 TTS 起播接上',
    );
    expect(ListeningSession.instance.playing, isTrue);

    // 看剧入口需要视频平台；匹配数据来自 mock 的 /video-match。
    // 先停掉朗读，否则新挂载的迷你胶囊会一直动，pumpAndSettle 等不到静止。
    ListeningSession.instance.clear();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await _mountReader(tester, store);
    await _openControls(tester);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderVideoButton), findsOneWidget);
    await tester.tap(find.byType(ReaderVideoButton));
    await tester.pumpAndSettle();

    // 目录请求失败时留在阅读页并给出统一提示：证明走完了真实启动链路。
    expect(find.byType(ReaderPage), findsOneWidget);
    expect(find.text('改编剧暂时无法打开，请稍后重试'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [
    const Size(320, 560),
    const Size(280, 640),
    const Size(640, 280),
    const Size(560, 320),
  ]) {
    testWidgets('$size 大字号下逐个滚动并点击经典入口', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fired = <String>[];
      await tester.pumpWidget(_chromeHarness(size, fired));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      const entries = {
        'reader-back-entry': 'back',
        'reader-cache': 'cache',
        'reader-toolbar-chapter-comments': 'comments',
        'reader-shelf-button': 'shelf',
        'reader-share': 'share',
        'reader-classic-more': 'more',
        'reader-classic-previous-chapter': 'previous',
        'reader-classic-next-chapter': 'next',
        'reader-catalogue-entry': 'directory',
        'reader-ai': 'ai',
        'reader-night-entry': 'night',
        'reader-settings': 'appearance',
      };
      for (final entry in entries.entries) {
        final finder = find.byKey(ValueKey(entry.key));
        expect(finder, findsOneWidget, reason: '${entry.key} 缺失');
        // 窄屏/横屏大字号：先滚到入口再点，证明横滑/纵向滚动后仍能命中。
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        fired.clear();
        await tester.tap(finder);
        await tester.pump();
        expect(fired, [
          entry.value,
        ], reason: '${entry.key} 在 $size 滚动后没有命中正确回调');
        expect(tester.takeException(), isNull);
      }

      // 动作合并为一行后，窄屏/横屏也不拆回两行。
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('reader-settings'))).dy,
        tester
            .getTopLeft(find.byKey(const ValueKey('reader-catalogue-entry')))
            .dy,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

// ── fixtures ────────────────────────────────────────────────────────────────

Future<http.Response> _apiHandler(http.Request request) async {
  final path = request.url.path;
  // The 看剧 entry stops before navigation: a directory error is surfaced as
  // its real user-visible retry message. Answering with a payload would go on
  // to `parseDirectoryAsync`, which uses a real isolate the fake async clock
  // cannot drive.
  if (path.endsWith('/directory') || path.contains('/detail')) {
    return http.Response(
      jsonEncode({'code': 500, 'message': 'boom'}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
  Object data = const <String, Object>{};
  if (path.endsWith('/video-match')) {
    data = const {
      'match_video_id': '9001',
      'novel_match_max_item_id': 'c1',
      'NovelToVideoMap': {
        'c1': [
          {'series_id': '9001', 'video_id': 'ep1'},
        ],
      },
    };
  }
  return http.Response(
    jsonEncode({'code': 0, 'data': data}),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

ChapterIdeas _ideas() => ChapterIdeas.fromPayload(const {
  'code': 0,
  'data': {
    'data': {
      '0': {
        'count': 3,
        'infos': [
          {'comment_id': 'c1'},
        ],
      },
    },
  },
});

Future<void> _mountReader(
  WidgetTester tester,
  AppThemeStyleStore store, {
  Size size = const Size(390, 844),
  String bookId = 'reader-classic-chrome',
  List<String>? loads,
  MemoryReaderStore? readerStore,
  MemoryChapterCache? chapterCache,
  ChapterTextLoader? chapterLoader,
  ReaderBookmarkStore? bookmarkStore,
  ChapterIdeasLoader? ideasLoader,
  ParagraphCommentResolver? commentResolver,
  Map<String, Object> preferences = const {},
  bool disableAnimations = false,
  bool audioScope = false,
}) async {
  SharedPreferences.setMockInitialValues(preferences);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final navigatorKey = GlobalKey<NavigatorState>();
  Widget page = ReaderPage(
    bookId: bookId,
    title: '经典外壳测试',
    chapters: [
      Chapter(itemId: 'c1', title: '第一章', volumeName: '正文'),
      Chapter(itemId: 'c2', title: '第二章', volumeName: '正文'),
      Chapter(itemId: 'c3', title: '第三章', volumeName: '正文'),
      Chapter(itemId: 'c4', title: '第四章', volumeName: '正文'),
    ],
    startIndex: 0,
    readerDevice: _Device(),
    readerStore: readerStore ?? MemoryReaderStore(),
    chapterCache: chapterCache ?? MemoryChapterCache(),
    bookmarkStore: bookmarkStore,
    ideasLoader: ideasLoader,
    commentResolver: commentResolver,
    chapterLoader: (chapter) async {
      loads?.add(chapter.itemId);
      if (chapterLoader != null) return chapterLoader(chapter);
      return List.generate(30, (index) => '第 $index 段用于经典外壳测试。').join('\n\n');
    },
  );
  if (audioScope) {
    page = AudioPlaybackScope(navigatorKey: navigatorKey, child: page);
  }
  if (disableAnimations) {
    final reader = page;
    page = Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: reader,
      ),
    );
  }
  await tester.pumpWidget(
    AppUiHost(
      store: store,
      navigatorKey: audioScope ? navigatorKey : null,
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

Widget _chromeHarness(Size size, List<String> fired) => MaterialApp(
  theme: AppTheme.createTheme(Brightness.light, style: AppThemeStyle.classic),
  home: MediaQuery(
    data: MediaQueryData(size: size, textScaler: const TextScaler.linear(2)),
    child: Scaffold(
      body: Column(
        children: [
          ReaderClassicToolbar(
            preset: ReaderThemePreset.light,
            showCache: true,
            showComments: true,
            inShelf: true,
            onBack: () => fired.add('back'),
            onCache: () => fired.add('cache'),
            onComments: () => fired.add('comments'),
            onShelf: () => fired.add('shelf'),
            onShare: () => fired.add('share'),
            onMore: () => fired.add('more'),
          ),
          const Spacer(),
          ReaderClassicControls(
            preset: ReaderThemePreset.light,
            chapterIndex: 11,
            chapterCount: 345,
            chapterTitleAt: (index) => '第 ${index + 1} 章 · 很长的章节名',
            onPrevious: () => fired.add('previous'),
            onNext: () => fired.add('next'),
            onSeekEnd: (_) => fired.add('seek'),
            onDirectory: () => fired.add('directory'),
            onNight: () => fired.add('night'),
            onAppearance: () => fired.add('appearance'),
            onAi: () => fired.add('ai'),
          ),
        ],
      ),
    ),
  ),
);

// ── helpers ─────────────────────────────────────────────────────────────────

void _expectClassicToast(WidgetTester tester, String message) {
  final toast = find.byKey(const ValueKey('reader-toast'));
  expect(toast, findsOneWidget);
  final text = find.descendant(of: toast, matching: find.text(message));
  expect(text, findsOneWidget);
  final viewport = tester.getRect(find.byType(ReaderPage));
  final rect = tester.getRect(toast);
  expect(rect.top, closeTo(viewport.top + viewport.height * .15, 1));
  expect(rect.center.dx, closeTo(viewport.center.dx, .5));
  expect(rect.width, closeTo(tester.getSize(text).width + 40, 1));
  expect(rect.height, lessThan(64));
  final material = tester.widget<Material>(toast);
  expect(material.color, const Color(0xFF424242));
  expect(material.borderRadius, BorderRadius.circular(48));
  expect(tester.widget<Text>(text).style?.color, Colors.white);
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

/// Waits for Hive's real (non fake-async) shelf write before asserting.
Future<void> _settleShelfWrite(WidgetTester tester, String expectedText) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.text(expectedText).evaluate().isNotEmpty) break;
    await tester.pump(const Duration(milliseconds: 400));
  }
  await tester.pump(const Duration(milliseconds: 300));
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

double _topOf(WidgetTester tester, String key) =>
    tester.getTopLeft(find.byKey(ValueKey(key))).dy;

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

double _percentOf(String text) =>
    double.parse(RegExp(r'([\d.]+)%').firstMatch(text)!.group(1)!);

bool _isSolidTopBar(WidgetTester tester) =>
    tester
        .widget<Material>(find.byKey(const ValueKey('reader-classic-toolbar')))
        .color ==
    ReaderThemePreset.light.panelColor;

class _CountingStore extends MemoryReaderStore {
  int writes = 0;

  @override
  Future<void> addHistory(Map<String, dynamic> value) async {
    writes++;
    await super.addHistory(value);
  }
}

class _Bookmarks extends ReaderBookmarkStore {
  final entries = <ReaderBookmark>[];

  @override
  Future<List<ReaderBookmark>> loadBook(String bookId) async =>
      entries.where((mark) => mark.bookId == bookId).toList();

  @override
  Future<void> add(ReaderBookmark mark) async {
    entries.removeWhere((entry) => entry.key == mark.key);
    entries.add(mark);
    changes.value++;
  }

  @override
  Future<void> remove(String key) async {
    entries.removeWhere((entry) => entry.key == key);
    changes.value++;
  }
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
