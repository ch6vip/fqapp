import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
import 'package:fqapp/services/reader_bookmark_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/app_ui/app_ui_scope.dart';
import 'package:fqapp/widgets/reader/reader_chapter_progress.dart';
import 'package:fqapp/widgets/reader/reader_chrome.dart';
import 'package:fqapp/widgets/reader/reader_classic_chrome.dart';
import 'package:fqapp/widgets/reader/reader_controls.dart';
import 'package:fqapp/widgets/reader/reader_listen_button.dart';
import 'package:fqapp/widgets/reader/reader_paged_view.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';
import 'package:fqapp/widgets/reader/reader_video_button.dart';

import 'support/app_ui_host.dart';
import 'support/fakes.dart';

/// Classic reader chrome (PR #292 task C) against the one live ReaderPage.
///
/// The two progress controls are covered separately on purpose: the classic
/// sheet's whole-book picker only loads a chapter on release, while the
/// chapter-internal row keeps the existing preview/commit lifecycle.
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
    expect(find.byKey(const ValueKey('reader-classic-more')), findsOneWidget);

    // 底部：整块上圆角面板、整书选章滑条、章内进度、单行动作。
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

    // 动作合并为一行：目录接替操作的位置，查找留在动作行，书签移入顶栏
    // “更多”菜单，操作入口移除。
    for (final key in [
      'reader-catalogue-entry',
      'reader-find-entry',
      'reader-night-entry',
      'reader-settings',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '$key 缺失');
      expect(_actionEnabled(tester, key), isTrue, reason: '$key 未接线');
    }
    expect(
      find.byKey(const ValueKey('reader-classic-action-row')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reader-classic-nav-row')), findsNothing);
    expect(
      find.byKey(const ValueKey('reader-classic-feature-row')),
      findsNothing,
    );
    final actionTops = {
      for (final key in [
        'reader-catalogue-entry',
        'reader-find-entry',
        'reader-night-entry',
        'reader-settings',
      ])
        _topOf(tester, key),
    };
    expect(actionTops, hasLength(1), reason: '目录/夜间/查找/设置在同行');
    for (final key in ['reader-bookmarks-entry', 'reader-operations-entry']) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: '$key 应已移出底部动作行');
    }
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('夜间'), findsOneWidget);
    expect(find.text('查找'), findsOneWidget);
    expect(find.text('书签'), findsNothing);
    expect(find.text('操作'), findsNothing);

    // 听/看胶囊仍走当前 _buildReaderMenuPlayers。
    expect(find.byKey(const ValueKey('reader-listen-entry')), findsOneWidget);
    // 经典分支不画玻璃坞与边缘模糊。
    expect(find.byKey(const ValueKey('reader-liquid-dock')), findsNothing);
    expect(find.byType(ReaderEdgeBlur), findsNothing);
    expect(find.byType(ReaderControls), findsNothing);
    // 生产 scope 全程在场，本次没有任何主题回退读取。
    expect(AppUiScope.debugFallbackReads, 0);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('经典顶栏“更多”打开二级菜单，只保留动作入口', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    await _mountReader(tester, store, ideasLoader: (_) async => _ideas());
    await _openControls(tester);

    await tester.tap(find.byKey(const ValueKey('reader-classic-more')));
    await tester.pumpAndSettle();

    // 二级菜单打开时顶栏和底板都还在，不会顺带收起。
    expect(
      find.byKey(const ValueKey('reader-classic-toolbar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-classic-controls-panel')),
      findsOneWidget,
    );
    for (final label in ['缓存', '本章评论', '加入书架', '书签']) {
      expect(find.text(label), findsOneWidget, reason: '二级菜单缺少 $label');
    }
    // 阅读设置 / 隐藏控件已从经典菜单移除：设置走底板，收起点正文中央。
    expect(find.text('阅读设置'), findsNothing);
    expect(find.text('专注阅读 · 隐藏控件'), findsNothing);
    // 菜单条目使用 classic- 前缀，和顶栏直连按钮的 key 不冲突。
    expect(
      find.byKey(const ValueKey('classic-reader-more-settings')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('classic-reader-more-hide')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('classic-reader-cache')), findsOneWidget);
    // 查找仍在底部动作行，不再进二级菜单。
    expect(
      find.byKey(const ValueKey('classic-reader-find-entry')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('classic-reader-bookmarks-entry')),
      findsOneWidget,
    );
    // preferBelow：菜单开在“更多”按钮下方，不盖住顶栏触发按钮。
    expect(
      tester.getRect(find.byKey(const ValueKey('classic-reader-cache'))).top,
      greaterThanOrEqualTo(
        tester
            .getRect(find.byKey(const ValueKey('reader-classic-more')))
            .bottom,
      ),
    );

    // 紧凑右对齐：卡片按标签收窄（不再固定 248dp），右边缘贴住“更多”，
    // 颜色取自当前阅读主题的 panelColor。
    final surface = find.byKey(const ValueKey('reader-classic-menu-surface'));
    final surfaceRect = tester.getRect(surface);
    final moreRect = tester.getRect(
      find.byKey(const ValueKey('reader-classic-more')),
    );
    expect(surfaceRect.width, lessThan(232), reason: '经典菜单应按内容收窄');
    expect(surfaceRect.width, greaterThanOrEqualTo(168));
    // 贴右：菜单右缘对齐锚点右缘，最多被弹层安全边距（12dp）内收。
    expect(
      moreRect.right - surfaceRect.right,
      inInclusiveRange(0, 12),
      reason: '菜单应右对齐锚点',
    );
    // 行宽对齐：短标签（缓存）和长标签（加入书架）左缘一致。
    expect(
      tester.getRect(find.byKey(const ValueKey('classic-reader-cache'))).left,
      tester
          .getRect(find.byKey(const ValueKey('classic-reader-shelf-button')))
          .left,
    );
    expect(
      tester.widget<Material>(surface).color,
      ReaderThemePreset.light.panelColor,
    );

    // 关闭菜单本身不会收起阅读界面。
    await tester.tapAt(const Offset(24, 700));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('classic-reader-cache')), findsNothing);
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

  testWidgets('经典底栏的章内进度按 preview/commit 生效且不逐帧写盘', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    final history = _CountingStore();
    await _mountReader(tester, store, readerStore: history);
    await _openControls(tester);

    final before = _textOf(tester, 'reader-progress');
    expect(_percentOf(before), 0);
    final writesBefore = history.writes;

    final slider = find.byKey(
      const ValueKey('reader-classic-chapter-progress'),
    );
    final rect = tester.getRect(slider);
    final gesture = await tester.startGesture(
      rect.centerLeft + const Offset(16, 0),
    );
    await tester.pump();
    await gesture.moveTo(rect.center);
    await tester.pump();
    await gesture.moveTo(rect.centerRight - const Offset(16, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    // 拖动期间不出章、不关底栏，也不落盘中间位置。
    expect(_textOf(tester, 'reader-classic-seek-position'), '1 / 4');
    expect(
      find.byKey(const ValueKey('reader-classic-controls')),
      findsOneWidget,
    );
    expect(history.writes, writesBefore, reason: '拖动中不应写阅读进度');

    await gesture.up();
    await tester.pumpAndSettle();

    final after = _textOf(tester, 'reader-progress');
    expect(_percentOf(after), greaterThan(_percentOf(before)));
    expect(_textOf(tester, 'reader-classic-chapter-label'), '正在阅读 · 第 1 章');
    // 松手后只落一次，且落在当前章。
    expect(history.writes, greaterThan(writesBefore));
    expect(history.entry?['chapterId'], 'c1');
    // 无障碍语义仍是「本章进度」，与档案主题同一套。
    expect(
      find.byKey(const ValueKey('reader-slider-semantics-本章进度')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('拖动章内进度中途切风格：收尾不抛异常且停在原章', (tester) async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    await store.select(AppThemeStyle.classic);
    final loads = <String>[];
    await _mountReader(tester, store, loads: loads);
    await _openControls(tester);

    final rect = tester.getRect(
      find.byKey(const ValueKey('reader-classic-chapter-progress')),
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
    expect(_textOf(tester, 'reader-progress'), isNot('全书 0.0%'));
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

    // 查找：底部动作行直接打开章内查找（经典面板由 body 自己管理滚动，
    // 不套外框的 scrollKey，因此按标题和输入框断言）。
    await openAction('reader-find-entry');
    expect(find.text('章内查找'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-find-field')), findsOneWidget);
    await closePanel('reader-find-field');

    // 书签：已移入顶栏“更多阅读操作”菜单；面板能加书签，记录落在注入的
    // store 且锚在当前章。
    await _openControls(tester);
    final more = find.byKey(const ValueKey('reader-classic-more'));
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('classic-reader-bookmarks-entry')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-bookmarks-scroll')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reader-add-bookmark')));
    await tester.pumpAndSettle();
    expect(bookmarks.entries, hasLength(1));
    expect(bookmarks.entries.single.chapterId, 'c1');
    expect(bookmarks.entries.single.text, isNotEmpty);
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
    expect(_topAction(tester, 'reader-shelf-button').tooltip, '已在书架');

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
        'reader-classic-more': 'more',
        'reader-catalogue-entry': 'directory',
        'reader-ai': 'ai',
        'reader-find-entry': 'find',
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
    chapterCache: MemoryChapterCache(),
    bookmarkStore: bookmarkStore,
    ideasLoader: ideasLoader,
    commentResolver: commentResolver,
    chapterLoader: (chapter) async {
      loads?.add(chapter.itemId);
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
            title: '很长很长的书名用来压住整行标题测试省略号',
            chapterNumber: 12,
            showCache: true,
            showComments: true,
            inShelf: true,
            onBack: () => fired.add('back'),
            onCache: () => fired.add('cache'),
            onComments: () => fired.add('comments'),
            onShelf: () => fired.add('shelf'),
            onMore: (_) => fired.add('more'),
          ),
          const Spacer(),
          ReaderClassicControls(
            preset: ReaderThemePreset.light,
            chapterIndex: 11,
            chapterCount: 345,
            chapterTitleAt: (index) => '第 ${index + 1} 章 · 很长的章节名',
            fraction: 0.42,
            onPrevious: () => fired.add('previous'),
            onNext: () => fired.add('next'),
            onSeekEnd: (_) => fired.add('seek'),
            onPreview: (_) {},
            onCommitted: (_) => fired.add('chapter-progress'),
            onPreviewChanged: (_) {},
            onDirectory: () => fired.add('directory'),
            onFind: () => fired.add('find'),
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

IconButton _topAction(WidgetTester tester, String key) {
  final finder = find.byKey(ValueKey(key));
  final widget = tester.widget(finder);
  return widget is IconButton
      ? widget
      : tester.widget<IconButton>(
          find.descendant(of: finder, matching: find.byType(IconButton)),
        );
}

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

BorderRadiusGeometry _panelRadius(WidgetTester tester, String key) =>
    tester.widget<Material>(find.byKey(ValueKey(key))).borderRadius!;

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
