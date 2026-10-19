import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/inline_video_playback.dart';
import 'package:fqapp/services/player_pool.dart';

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
  });

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

    // B 在 A 仍被门挡住时接管：A 还不是可复用解码器，不能占池位。
    await session.activate(_series('b'));
    expect(session.activeId.value, 'b');
    expect(session.playing.value, isTrue);
    expect(session.pool.peek('a'), isNull);
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

  test('换档选择按集记住，播放器被淘汰后仍按所选清晰度重建', () async {
    final session = InlineVideoPlayback(
      directoryLoader: (id, tab) async => [
        [Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集')],
      ],
      contentLoader: (itemId, tab) async => {
        'video_url': 'https://example.invalid/$itemId-1080.mp4',
        'variants': [
          {
            'name': '1080P',
            'url': 'https://example.invalid/$itemId-1080.mp4',
            'height': 1080,
          },
          {
            'name': '540P',
            'url': 'https://example.invalid/$itemId-540.mp4',
            'height': 540,
          },
        ],
      },
      historyStore: MemoryReaderStore(),
      pool: PlayerPool(capacity: 1),
      playerFactory: ControlledNativePlayer.new,
    );
    addTearDown(session.dispose);

    await session.activate(_series('a'));
    expect(session.variants, hasLength(2));
    await session.switchVariant(session.variants[1]);
    expect(session.hasPlayer, isTrue);

    await session.activate(_series('b'));
    await session.activate(_series('c'));
    expect(session.pool.peek('a'), isNull);

    await session.activate(_series('a'));
    expect(session.currentVariant?.name, '540P');
  });

  test('池内复用恢复该剧画质源，不沿用上一部剧', () async {
    final players = <ControlledNativePlayer>[];
    final session = InlineVideoPlayback(
      directoryLoader: (id, tab) async => [
        [Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集')],
      ],
      contentLoader: (itemId, tab) async => {
        'video_url': 'https://example.invalid/$itemId-1080.mp4',
        'variants': [
          {
            'name': '1080P',
            'url': 'https://example.invalid/$itemId-1080.mp4',
            'height': 1080,
          },
          {
            'name': '540P',
            'url': 'https://example.invalid/$itemId-540.mp4',
            'height': 540,
          },
        ],
      },
      historyStore: MemoryReaderStore(),
      playerFactory: () {
        final player = ControlledNativePlayer();
        players.add(player);
        return player;
      },
    );
    addTearDown(session.dispose);

    await session.activate(_series('a'));
    await session.activate(_series('b'));
    await session.activate(_series('a'));

    expect(session.reusedFromPool, isTrue);
    expect(players, hasLength(2));
    expect(session.variants.first.url, contains('/a-1-1080.mp4'));

    await session.switchVariant(session.variants[1]);
    expect(players, hasLength(3));
    expect(
      players.last.calls.whereType<String>().singleWhere(
        (call) => call.startsWith('create:'),
      ),
      contains('/a-1-540.mp4'),
    );
  });

  test('迟到的上一部取流不能覆盖池复用后的画质源', () async {
    final bSourceStarted = Completer<void>();
    final releaseBSource = Completer<void>();
    final session = InlineVideoPlayback(
      directoryLoader: (id, tab) async => [
        [Chapter(itemId: '$id-1', title: '第 1 集', volumeName: '剧集')],
      ],
      contentLoader: (itemId, tab) async {
        if (itemId == 'b-1') {
          bSourceStarted.complete();
          await releaseBSource.future;
        }
        return {
          'video_url': 'https://example.invalid/$itemId-1080.mp4',
          'variants': [
            {
              'name': '1080P',
              'url': 'https://example.invalid/$itemId-1080.mp4',
              'height': 1080,
            },
            {
              'name': '540P',
              'url': 'https://example.invalid/$itemId-540.mp4',
              'height': 540,
            },
          ],
        };
      },
      historyStore: MemoryReaderStore(),
      playerFactory: ControlledNativePlayer.new,
    );
    addTearDown(session.dispose);

    await session.activate(_series('a'));
    final activatingB = session.activate(_series('b'));
    await bSourceStarted.future;
    await session.activate(_series('a'));
    expect(session.reusedFromPool, isTrue);

    releaseBSource.complete();
    await activatingB;

    expect(session.activeId.value, 'a');
    expect(session.variants.first.url, contains('/a-1-1080.mp4'));
  });
}
