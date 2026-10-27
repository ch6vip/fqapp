import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/services/drama_cache_preferences.dart';
import 'package:fqapp/services/drama_downloader.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/services/quality_memory.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

const _nativePlayerChannel = MethodChannel('fqapp/native_player');

/// connectivity_plus 的方法通道。测试宿主里不打桩只会拿到 null（读成
/// 「断网」），要复现「插件没注册 / 通道报错」得让它抛。
const _connectivityChannel = MethodChannel(
  'dev.fluttercommunity.plus/connectivity',
);

/// 播放页里「边看边往后缓存」的三个判定：网络形态未知时是否跳过、画质上限
/// 跟的是哪一档、早退之后还能不能补上。
void main() {
  late MemoryDramaDownloadStore store;
  late DramaDownloader downloader;
  late Completer<EpisodeSource> blocked;
  late List<ControlledNativePlayer> players;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DramaCachePreferences.instance.resetForTest();
    QualityMemory.clearForTesting();
    // 目录直接用系统临时目录：下载器一进 _runOnce 就先问目录，测试里不必
    // 真建临时目录，也不会走到真正的取流与网络。
    store = MemoryDramaDownloadStore(videoDirectory: Directory.systemTemp);
    blocked = Completer<EpisodeSource>();
    downloader = DramaDownloader(store: store, resolve: (_) => blocked.future);
    players = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativePlayerChannel, (call) async => null);
  });

  tearDown(() {
    QualityMemory.clearForTesting();
    DramaCachePreferences.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativePlayerChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, null);
  });

  void mockConnectivity(List<String> results) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_connectivityChannel, (call) async => results);
  }

  void mockConnectivityError() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _connectivityChannel,
          (call) async => throw PlatformException(code: 'unavailable'),
        );
  }

  Future<void> mount(
    WidgetTester tester, {
    required Future<Map<String, dynamic>> Function(Chapter) loader,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          bookId: 'auto-cache-series',
          title: '自动缓存测试',
          eps: [
            for (var number = 1; number <= 6; number++)
              Chapter(itemId: '$number', title: '第 $number 集', volumeName: ''),
          ],
          startIndex: 0,
          shortSeries: true,
          historyStore: MemoryReaderStore(),
          danmakuFetcher: (_) async => const PlayletCommentPage(),
          contentLoader: loader,
          playerFactory: () {
            final player = ControlledNativePlayer(hasFirstFrame: true);
            players.add(player);
            return player;
          },
          store: store,
          downloader: downloader,
        ),
      ),
    );
    await _flush(tester);
  }

  testWidgets('测不出网络形态时不动自动缓存', (tester) async {
    // 平台通道报错时 currentConnectivity() 报「在线且不计费」——那是给
    // 手动下载入口的（不能把入口误关死）。自动缓存没有流量确认兜底，
    // 一集几十 MB，这里必须按「不是 Wi-Fi」跳过，而不是跟着 fail-open 走。
    mockConnectivityError();
    await mount(tester, loader: (chapter) async => _source(chapter.itemId));
    expect(players, hasLength(1), reason: '起播本身不受影响');

    await tester.pump(const Duration(seconds: 2));
    await _flush(tester);

    expect(downloader.value, isEmpty);
  });

  testWidgets('网络未知时早退不会锁死这一集，Wi-Fi 恢复后还能补上', (tester) async {
    mockConnectivityError();
    await mount(tester, loader: (chapter) async => _source(chapter.itemId));
    await tester.pump(const Duration(seconds: 2));
    await _flush(tester);
    expect(downloader.value, isEmpty);

    // 回到 Wi-Fi 后再出一次首帧（重试/换流都会再触发），这一集必须还能排。
    mockConnectivity(['wifi']);
    players.single.emitFirstFrame();
    await _flush(tester);
    await tester.pump(const Duration(seconds: 2));
    await _flush(tester);

    expect(
      downloader.value,
      isNotEmpty,
      reason: '早退的那一次不该把这一集永久记成「已排过」',
    );
    expect(downloader.value.first.auto, isTrue);
  });

  testWidgets('自动缓存的画质上限跟选中那一档，不是列表里第一条', (tester) async {
    // 上游偶尔把两个画质名指向同一条流（同 url、不同高度）。按 url 反查
    // 只会拿到第一条 1080，而实际在播的是选中的 720。
    QualityMemory.remember('auto-cache-series', '720P');
    mockConnectivity(['wifi']);
    await mount(
      tester,
      loader: (chapter) async => {
        'video_url': 'https://example.invalid/${chapter.itemId}-shared.mp4',
        'key_hex': '',
        'variants': [
          {
            'name': '1080P',
            'url': 'https://example.invalid/${chapter.itemId}-shared.mp4',
            'key_hex': '',
            'height': 1080,
          },
          {
            'name': '720P',
            'url': 'https://example.invalid/${chapter.itemId}-shared.mp4',
            'key_hex': '',
            'height': 720,
          },
        ],
      },
    );
    await tester.pump(const Duration(seconds: 2));
    await _flush(tester);

    expect(players.single.calls.first, contains('-shared.mp4'));
    expect(downloader.value, isNotEmpty);
    expect(downloader.value.first.maxHeight, 720);
  });

  testWidgets('播上游默认流时按解码高度封顶，而不是取最高档', (tester) async {
    // 没选过档时上游把 `video_url` 绑到哪一档客户端并不知道，靠 url 认不出
    // 任何一档，以前会因此退回 null = 取最高档。解码完就有答案了，以实际
    // 解码高度封顶。
    mockConnectivity(['wifi']);
    await mount(
      tester,
      loader: (chapter) async => {
        'video_url': 'https://example.invalid/${chapter.itemId}.mp4',
        'key_hex': '',
        'variants': [
          {
            'name': '1080P',
            'url': 'https://example.invalid/${chapter.itemId}-1080.mp4',
            'key_hex': '',
            'height': 1080,
          },
        ],
      },
    );
    players.single.height = 480;
    await tester.pump(const Duration(seconds: 2));
    await _flush(tester);

    expect(downloader.value, isNotEmpty);
    expect(downloader.value.first.maxHeight, 480);
  });
}

Map<String, dynamic> _source(String id) => {
  'video_url': 'https://example.invalid/$id.mp4',
};

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}
