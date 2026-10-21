import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/player_page.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/player_style_config.dart';

import 'support/controlled_player.dart';

void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 书详情页走真实 ChapterCacheStore，需要 Hive。
    directory = await Directory.systemTemp.createTemp('fqapp-nav-pause-');
    Hive.init(directory.path);
    // 发布的 config.json 显式打开新底栏：旧底栏初始化即清屏，
    // 标题行与原著卡不渲染，测不到跳转。
    PlayerStyleConfig.instance = const PlayerStyleConfig(
      useNewPlayerBottomStyle: true,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (call) async => null,
        );
  });
  tearDown(() async {
    PlayerStyleConfig.instance = PlayerStyleConfig.defaults;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          null,
        );
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('original-book card pauses video and resumes on return', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      await tester.binding.setSurfaceSize(null);
    });

    final store = ControlledReaderStore();
    final player = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 10);
    await tester.pumpWidget(
      _app(store: store, player: player, detail: _detail()),
    );
    await _flush(tester);
    expect(player.isPlaying, isTrue);

    // 原著书卡 → 书详情：视频必须暂停（#39：之前一直在阅读页下面播）。
    await tester.tap(find.byKey(const ValueKey('player-original-book')));
    await _settle(tester);
    expect(find.byType(DetailPage), findsOneWidget);
    expect(player.isPlaying, isFalse);

    // 返回播放页：按原状态续播。
    await _pop(tester, DetailPage);
    expect(player.isPlaying, isTrue);
  });

  testWidgets('series title pauses video and resumes on return', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      await tester.binding.setSurfaceSize(null);
    });

    final store = ControlledReaderStore();
    final player = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 10);
    await tester.pumpWidget(
      _app(store: store, player: player, detail: _detail()),
    );
    await _flush(tester);
    expect(player.isPlaying, isTrue);

    // 标题行 → 剧详情：视频必须暂停；从详情再往深走也不会在下面偷播。
    await tester.tap(find.byKey(const ValueKey('player-series-title')));
    await _settle(tester);
    expect(find.byType(SeriesDetailPage), findsOneWidget);
    expect(player.isPlaying, isFalse);

    await _pop(tester, SeriesDetailPage);
    expect(player.isPlaying, isTrue);
  });

  testWidgets('selecting another episode from detail does not resume the old one', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      await tester.binding.setSurfaceSize(null);
    });

    final store = ControlledReaderStore();
    final oldPlayer = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 10);
    // 挡住旧播放器的释放：让续播守卫的判定发生在释放完成之前，
    // 漏了守卫时旧播放器会多一次 play 调用。
    oldPlayer.releaseGate = Completer<void>();
    final newPlayer = ControlledNativePlayer()
      ..totalDuration = const Duration(minutes: 10);
    final created = <ControlledNativePlayer>[];
    await tester.pumpWidget(
      _app(
        store: store,
        player: oldPlayer,
        detail: _detail(),
        playerFactory: () {
          final next = created.isEmpty ? oldPlayer : newPlayer;
          created.add(next);
          return next;
        },
      ),
    );
    await _flush(tester);
    expect(oldPlayer.isPlaying, isTrue);
    expect(oldPlayer.calls.where((c) => c == 'play').length, 1);

    await tester.tap(find.byKey(const ValueKey('player-series-title')));
    await _settle(tester);
    expect(find.byType(SeriesDetailPage), findsOneWidget);
    expect(oldPlayer.isPlaying, isFalse);

    // 详情页选第 2 集：pop + 切集，切集链路自己起新播放器；
    // 续播守卫必须跳过旧播放器，不给它补一次 play。
    final episodeTile = find.byKey(const ValueKey('series-episode-1'));
    await tester.ensureVisible(episodeTile);
    await tester.tap(episodeTile);
    await _settle(tester);
    await _flush(tester);
    expect(find.byType(SeriesDetailPage), findsNothing);
    expect(oldPlayer.calls.where((c) => c == 'play').length, 1);

    oldPlayer.releaseGate?.complete();
    await _flush(tester);
  });
}

SeriesDetail _detail() => SeriesDetail(
  seriesId: 'series-1',
  title: '抽象三国第一季',
  intro: '简介',
  cover: '',
  episodeCount: 2,
  episodeLabel: '全2集',
  playCount: 0,
  followerCount: 0,
  commentCount: 0,
  categories: const [],
  originalBook: const SeriesRelateBook(
    id: 'book-1',
    title: '原著书名',
    cover: '',
  ),
  status: 1,
  seriesColorHex: '',
);

Widget _app({
  required ControlledReaderStore store,
  required ControlledNativePlayer player,
  required SeriesDetail detail,
  ControlledNativePlayer Function()? playerFactory,
}) => MaterialApp(
  home: PlayerPage(
    bookId: 'series-1',
    title: '抽象三国第一季',
    kind: 'duanju',
    eps: [
      Chapter(itemId: '1', title: '第 1 集', volumeName: ''),
      Chapter(itemId: '2', title: '第 2 集', volumeName: ''),
    ],
    startIndex: 0,
    shortSeries: true,
    historyStore: store,
    contentLoader: (chapter) async => _source(chapter.itemId),
    playerFactory: playerFactory ?? () => player,
    initialSeriesDetail: detail,
    seriesLoader: (_) async => detail,
  ),
);

Map<String, dynamic> _source(String id) => {
  'video_url': 'https://example.invalid/$id.mp4',
};

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

/// 有界等待：路由 300ms 转场 + 异步加载。DetailPage 有常驻动画，
/// pumpAndSettle 会超时，不能用。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await _flush(tester);
  await tester.pump(const Duration(milliseconds: 350));
}

/// 详情页用自定义返回按钮，tester.pageBack() 找不到 Cupertino 返回键，
/// 直接 pop。
Future<void> _pop(WidgetTester tester, Type type) async {
  final context = tester.element(find.byType(type));
  Navigator.of(context).pop();
  await _settle(tester);
}
