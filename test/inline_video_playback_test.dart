import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/services/inline_video_playback.dart';
import 'package:fqapp/services/quality_memory.dart';

import 'support/controlled_player.dart';
import 'support/fakes.dart';

MediaItem _series(String id) => MediaItem(
  id: id,
  title: '$id 作品',
  cover: '',
  author: '演员',
  badge: '',
  ep: '全12集',
  kind: 'video',
  seriesId: id,
);

void main() {
  setUp(() {
    // 冷启动静音/倍速偏好经 SharedPreferences 读；会话内第一次建播放器
    // 时各读一次，测试里给空初始值即可。
    SharedPreferences.setMockInitialValues({});
    QualityMemory.clearForTesting();
  });
  tearDown(QualityMemory.clearForTesting);

  test('迟到 create 被丢弃：超前激活的播放器不被接管', () async {
    final gateA = Completer<void>();
    final players = <ControlledNativePlayer>[];
    var first = true;
    final session = InlineVideoPlayback(
      directoryLoader: (id, tab) async => [
        [Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集')],
      ],
      contentLoader: (itemId, tab) async => {
        'video_url': 'https://example.invalid/$itemId.mp4',
      },
      playerFactory: () {
        // 第一台播放器在 create 处被门挡住；之后建的都不挡。
        final player = ControlledNativePlayer(createGate: first ? gateA : null);
        first = false;
        players.add(player);
        return player;
      },
      historyStore: MemoryReaderStore(),
    );
    addTearDown(session.dispose);

    // A 开始建播放器，卡在 create 门前（解码器还没建出来）。
    final futureA = session.activate(_series('a'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(players, hasLength(1));
    expect(players[0].calls, contains(startsWith('create:')));

    // B 在 A 仍被门挡住时接管：A 被入池（不销毁），B 正常播。
    await session.activate(_series('b'));
    expect(session.activeId.value, 'b');
    expect(session.playing.value, isTrue);
    expect(players, hasLength(2));
    expect(players[1].calls, contains('play'));

    // A 的 create 终于落下：超前的激活必须销毁自己的播放器而不是接管
    // 会话；B 不受影响，仍在播。
    gateA.complete();
    await futureA;
    expect(players[0].disposed, isTrue);
    expect(players[0].calls, contains('dispose'));
    expect(session.activeId.value, 'b');
    expect(session.playing.value, isTrue);
    expect(session.hasPlayer, isTrue);
    expect(players[1].disposed, isFalse);
  });

  test('quality choice carries to the next episode by name (#60)', () async {
    final players = <ControlledNativePlayer>[];
    Map<String, dynamic> payload(String itemId) => {
      'video_url': 'https://example.invalid/$itemId-720.mp4',
      'variants': [
        {
          'name': '1080P',
          'url': 'https://example.invalid/$itemId-1080.mp4',
          'key_hex': '',
          'height': 1080,
        },
        {
          'name': '720P',
          'url': 'https://example.invalid/$itemId-720.mp4',
          'key_hex': '',
          'height': 720,
        },
      ],
    };
    final session = InlineVideoPlayback(
      directoryLoader: (id, tab) async => [
        [
          Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集'),
          Chapter(itemId: '$id-2', title: '第 2 集', volumeName: '剧集'),
        ],
      ],
      contentLoader: (itemId, tab) async => payload(itemId),
      playerFactory: () {
        final player = ControlledNativePlayer();
        players.add(player);
        return player;
      },
      historyStore: MemoryReaderStore(),
    );
    addTearDown(session.dispose);

    await session.activate(_series('a'));
    expect(
      players.single.calls,
      contains('create:https://example.invalid/a-1-720.mp4'),
    );

    await session.switchVariant(
      const EpisodeVariant(
        name: '1080P',
        url: 'https://example.invalid/a-1-1080.mp4',
        keyHex: '',
        height: 1080,
      ),
    );
    expect(
      players.last.calls,
      contains('create:https://example.invalid/a-1-1080.mp4'),
    );
    // The choice is shared with the full-page player via QualityMemory.
    expect(QualityMemory.nameFor('a'), '1080P');

    // Next episode keeps 1080P by NAME — its own URL, not episode 1's.
    await session.activate(_series('a'), startEpisodeIndex: 1);
    expect(
      players.last.calls,
      contains('create:https://example.invalid/a-2-1080.mp4'),
    );
    expect(session.activeEpisode?.itemId, 'a-2');
  });

  test('a choice remembered elsewhere is honored on activate', () async {
    // Simulates the full-page player (or another entry point) remembering
    // a quality for this series before the feed activates it.
    QualityMemory.remember('a', '1080P');
    final players = <ControlledNativePlayer>[];
    final session = InlineVideoPlayback(
      directoryLoader: (id, tab) async => [
        [
          Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集'),
        ],
      ],
      contentLoader: (itemId, tab) async => {
        'video_url': 'https://example.invalid/$itemId-720.mp4',
        'variants': [
          {
            'name': '1080P',
            'url': 'https://example.invalid/$itemId-1080.mp4',
            'key_hex': '',
            'height': 1080,
          },
          {
            'name': '720P',
            'url': 'https://example.invalid/$itemId-720.mp4',
            'key_hex': '',
            'height': 720,
          },
        ],
      },
      playerFactory: () {
        final player = ControlledNativePlayer();
        players.add(player);
        return player;
      },
      historyStore: MemoryReaderStore(),
    );
    addTearDown(session.dispose);

    await session.activate(_series('a'));
    expect(
      players.single.calls,
      contains('create:https://example.invalid/a-1-1080.mp4'),
    );
  });

  test('播下一集：旧解码器释放完成前不建新解码器', () async {
    // 同一部剧换集时旧解码器作废重建，新的必须等旧的释放结束。否则两台原生
    // 播放器同时存活：Android 撞 MediaCodec 名额、桌面端撞媒体会话未关闭，
    // 表现为「播下一集时提示播放失败」。
    final releaseGate = Completer<void>();
    final players = <ControlledNativePlayer>[];
    final session = InlineVideoPlayback(
      directoryLoader: (id, tab) async => [
        [
          Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集'),
          Chapter(itemId: '$id-2', title: '第 2 集', volumeName: '剧集'),
        ],
      ],
      contentLoader: (itemId, tab) async => {
        'video_url': 'https://example.invalid/$itemId.mp4',
      },
      playerFactory: () {
        final player = ControlledNativePlayer(
          // 只有第一台卡在释放门上，第二台正常建。
          releaseGate: players.isEmpty ? releaseGate : null,
        );
        players.add(player);
        return player;
      },
      historyStore: MemoryReaderStore(),
    );
    addTearDown(session.dispose);

    await session.activate(_series('a'));
    expect(session.activeEpisodeIndex, 0);
    expect(players, hasLength(1));
    expect(players.single.calls, contains('play'));

    final next = session.activate(_series('a'), startEpisodeIndex: 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      players,
      hasLength(1),
      reason: '旧解码器还在释放中，新解码器不能开始创建',
    );
    expect(players.single.calls, contains('dispose'));
    expect(
      players.single.calls,
      isNot(contains('released')),
      reason: '释放仍被门挡住，说明断言确实卡在中间态',
    );

    releaseGate.complete();
    await next;
    expect(players, hasLength(2));
    expect(players[0].calls, contains('released'));
    expect(players[1].calls, contains('create:https://example.invalid/a-2.mp4'));
    expect(players[1].calls, contains('play'));
    expect(session.activeEpisodeIndex, 1);
    expect(session.activeVid.value, 'a-2');
  });
}
