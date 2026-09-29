import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/listen_mode_page.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/services/player_preferences.dart';

import 'support/fakes.dart';

final _episodes = [
  Chapter(itemId: 'ep1', title: '第一集', volumeName: ''),
  Chapter(itemId: 'ep2', title: '第二集', volumeName: ''),
  Chapter(itemId: 'ep3', title: '第三集', volumeName: ''),
];

/// 主地址是 720P（key=kMain）：选档逻辑应挑与主地址同 URL 的画质档，
/// key 用档位自己的（k720），而不是主地址的 kMain。
final _source = EpisodeSource('u720', 'kMain', [
  EpisodeVariant(name: '1080P', url: 'u1080', keyHex: 'k1080', height: 1080),
  EpisodeVariant(name: '720P', url: 'u720', keyHex: 'k720', height: 720),
]);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'player_playback_rate': 1.0});
  });

  testWidgets('进入听书页：用当前画质档取流建播放器并自动开播', (tester) async {
    final created = <FakeNativePlayer>[];
    final resolved = <String>[];
    await _pump(tester, created: created, resolved: resolved);
    await tester.pumpAndSettle();

    expect(resolved, ['ep1']);
    expect(created, hasLength(1));
    expect(created.first.calls, contains('create:u720'));
    // key 走选中档位的（k720），不落回主地址的 kMain。
    expect(created.first.createdKeys, ['k720']);
    expect(created.first.calls, contains('rate:1.0'));
    expect(created.first.calls, contains('play'));
    expect(created.first.playWhenReady, isTrue);
    expect(find.byKey(const ValueKey('listen-page')), findsOneWidget);
    // 后台续听不注册生命周期暂停：页面存活即保持 playWhenReady。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(created.first.playbackRequested, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('播完自动连播下一集', (tester) async {
    final created = <FakeNativePlayer>[];
    final resolved = <String>[];
    await _pump(tester, created: created, resolved: resolved);
    await tester.pumpAndSettle();
    expect(resolved, ['ep1']);

    created.first.completedEvents.add(true);
    await tester.pumpAndSettle();
    expect(resolved, ['ep1', 'ep2']);
    expect(created, hasLength(2));
    expect(created[1].calls, contains('create:u720'));
    expect(created[1].calls, contains('play'));
    expect(find.text('第 2 集 · 第二集'), findsOneWidget);
  });

  testWidgets('返回回传 (集号, 进度) 给宿主', (tester) async {
    final created = <FakeNativePlayer>[];
    await _pump(tester, created: created);
    await tester.pumpAndSettle();
    created.first.currentPosition = const Duration(seconds: 45);
    await tester.tap(find.byKey(const ValueKey('listen-page-back')));
    await tester.pumpAndSettle();
    expect(popped, (0, const Duration(seconds: 45)));
  });

  testWidgets('连播跨集后回传新集号与该集进度', (tester) async {
    // 听书页在后台连播到第 2 集：退出必须把集号一起带回，宿主才能跟到
    // 第 2 集续看（官方 sync_progress_strategy_listen_mode 语义）。
    final created = <FakeNativePlayer>[];
    await _pump(tester, created: created);
    await tester.pumpAndSettle();
    created.first.completedEvents.add(true);
    await tester.pumpAndSettle();
    created[1].currentPosition = const Duration(seconds: 33);
    await tester.tap(find.byKey(const ValueKey('listen-page-back')));
    await tester.pumpAndSettle();
    expect(popped, (1, const Duration(seconds: 33)));
  });

  testWidgets('倍速药丸写全局速率并作用于当前播放器', (tester) async {
    final created = <FakeNativePlayer>[];
    await _pump(tester, created: created);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('listen-rate-1.25')));
    await tester.pumpAndSettle();
    expect(created.first.calls, contains('rate:1.25'));
    expect(await PlayerPreferences.loadPlaybackRate(), 1.25);
  });
}

/// 听书页是被推入的路由：宿主页按钮 push，pop 的回传值落在 [popped]
/// （(集号, 进度)）。
(int, Duration)? popped;

Future<void> _pump(
  WidgetTester tester, {
  required List<FakeNativePlayer> created,
  List<String>? resolved,
  int initialIndex = 0,
}) async {
  popped = null;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<(int, Duration)>(
                MaterialPageRoute<(int, Duration)>(
                  builder: (_) => ListenModePage(
                    seriesTitle: '测试剧',
                    coverUrl: 'https://cdn.example/cover.jpg',
                    episodes: _episodes,
                    initialIndex: initialIndex,
                    resolveSource: (episode) async {
                      resolved?.add(episode.itemId);
                      return _source;
                    },
                    playerFactory: () {
                      final fake = FakeNativePlayer();
                      created.add(fake);
                      return fake;
                    },
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
