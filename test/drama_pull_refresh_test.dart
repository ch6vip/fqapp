import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/drama_channel_preferences.dart';
import 'package:fqapp/services/swipe_guide_store.dart';

import 'support/controlled_player.dart';

MediaItem _item(String id) => MediaItem(
  id: id,
  title: '$id 作品',
  cover: '',
  author: '演员',
  badge: '',
  ep: '',
  kind: 'video',
);

HomeNotifier _notifier({int initialTabIndex = 0}) => HomeNotifier(
  initialTabIndex: initialTabIndex,
  homepageLoader:
      ({int tabType = 2, int offset = 0, String? sessionId}) async =>
          HomepagePage(
            // 两卡以上 feed 才可滚动；不可滚动的 PageView 不收下拉手势。
            items: [_item('$tabType-0'), _item('$tabType-1')],
            nextOffset: null,
            sessionId: null,
          ),
  searchLoader: (query, {int page = 1}) async => const [],
);

void main() {
  late Directory hiveDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 频道选择是进程级静态态：上一个用例的选择会带进下一个。
    DramaChannelPreferences.reset();
    hiveDir = await Directory.systemTemp.createTemp('fqapp-drama-pull-test-');
    Hive.init(hiveDir.path);
    // 「上滑查看更多视频」引导带 8s 定时器：按「已显示过」处理，免得留下
    // pending timer。
    await SwipeGuideStore.instance.init();
    await SwipeGuideStore.instance.markShown();
  });

  tearDown(() async {
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await hiveDir.delete(recursive: true);
    } catch (_) {
      // 临时目录清不掉只是噪音。
    }
  });

  testWidgets('下拉刷新：提示条跟手且不整页重建', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('fqapp/native_player'),
      (call) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('fqapp/native_player'),
        null,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(_notifier),
          dramaProvider.overrideWith(
            () => _notifier(initialTabIndex: dramaTabIndex),
          ),
        ],
        child: MaterialApp(
          home: DramaPage(
            // 取不到频道表 / 取流失败都要静默：本用例只关心下拉提示。
            channelLoader: () async => throw StateError('offline'),
            contentLoader: (itemId, tab) async =>
                throw const ApiException('内联取址不可用'),
            playerFactory: ControlledNativePlayer.new,
            historyStore: ControlledReaderStore(),
          ),
        ),
      ),
    );
    await _flush(tester);

    final feed = find.byKey(const Key('drama_feed'));
    expect(feed, findsOneWidget);
    expect(find.text('下拉刷新内容'), findsNothing);
    final topBarBefore = tester.widget(
      find.byKey(const ValueKey('drama_top_bar')),
    );

    // 首卡持续下拉：每一拍都是一次 Overscroll/ScrollUpdate 通知。
    final gesture = await tester.startGesture(tester.getCenter(feed));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
    }

    // 160px 下拉越过 64px 阈值：提示条进入「正在刷新内容」的就绪态。
    expect(find.text('正在刷新内容'), findsOneWidget, reason: '下拉越过阈值时要显示官方提示条');
    expect(
      identical(
        tester.widget(find.byKey(const ValueKey('drama_top_bar'))),
        topBarBefore,
      ),
      isTrue,
      reason: '下拉距离只该刷新提示条，不能每次滚动都整页 setState',
    );

    await gesture.up();
    await tester.pump();
    expect(find.text('下拉刷新内容'), findsNothing);
    expect(find.text('正在刷新内容'), findsNothing);
  });
}

/// 有界刷新：加载指示器在转时不能 pumpAndSettle。
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}
