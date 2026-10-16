import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/inline_video_playback.dart';

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
}
