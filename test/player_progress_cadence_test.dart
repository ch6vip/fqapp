import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/player_page.dart';

import 'support/controlled_player.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (_) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
  });

  testWidgets('播放中每 5 秒保存一次进度（与听书页同一节奏）', (tester) async {
    final store = ControlledReaderStore();
    final player = ControlledNativePlayer();
    await _mount(tester, store, player);
    player.emitPosition(const Duration(seconds: 33));
    await tester.pump();
    final baseline = store.writes.length;

    // 2 秒不再是保存点：心跳与听书页对齐到 5s。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(store.writes.length, baseline, reason: '保存节奏不该还是每 2s 一次');

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(store.writes.length, baseline + 1);
    expect(store.writes.last['position'], 33);
  });

  testWidgets('暂停立即落盘：心跳变长也不会丢最新进度', (tester) async {
    final store = ControlledReaderStore();
    final player = ControlledNativePlayer();
    await _mount(tester, store, player);
    player.emitPosition(const Duration(seconds: 47));
    await tester.pump();
    final baseline = store.writes.length;

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(store.writes.length, baseline + 1, reason: '暂停必须立即保存，不能等下一个 5s 心跳');
    expect(store.writes.last['position'], 47);
  });

  testWidgets('退出播放页立即落盘', (tester) async {
    final store = ControlledReaderStore();
    final player = ControlledNativePlayer();
    await _mount(tester, store, player);
    player.emitPosition(const Duration(seconds: 51));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(store.writes.last['position'], 51);
  });
}

Future<void> _mount(
  WidgetTester tester,
  ControlledReaderStore store,
  ControlledNativePlayer player,
) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        bookId: 'series',
        title: '短剧',
        eps: [
          Chapter(itemId: '1', title: '第一集', volumeName: ''),
          Chapter(itemId: '2', title: '第二集', volumeName: ''),
        ],
        startIndex: 0,
        contentLoader: (chapter) async => {
          'data': {'video_url': 'https://cdn.example/${chapter.itemId}.mp4'},
        },
        playerFactory: () => player,
        historyStore: store,
      ),
    ),
  );
  await _flush(tester);
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}
