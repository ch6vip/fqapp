import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/player_pool.dart';

import 'support/controlled_player.dart';

/// The pool mirrors the official `ShortPlayerSharePool` (`gq3/b.java`): a player
/// parked under a key comes back instead of being rebuilt, and the map is
/// bounded so parked decoders cannot pile up.
void main() {
  test('park 后可以按 key 取回同一个播放器', () {
    final pool = PlayerPool();
    final player = ControlledNativePlayer();

    pool.park('series-a', player);
    expect(pool.length, 1);
    expect(pool.keys, ['series-a']);
    expect(pool.peek('series-a')?.player, same(player));

    final taken = pool.acquire('series-a');
    expect(taken?.player, same(player));
    // acquire 是取走语义：取走后池里就没有了。
    expect(pool.length, 0);
    expect(pool.acquire('series-a'), isNull);
  });

  test('park 携带的 payload 原样保留', () {
    final pool = PlayerPool();
    pool.park('a', ControlledNativePlayer(), payload: 'session-state');
    expect(pool.peek('a')?.payload, 'session-state');
  });

  test('超出容量时淘汰最早放入的播放器并销毁它', () async {
    final pool = PlayerPool(capacity: 2);
    final first = ControlledNativePlayer();
    final second = ControlledNativePlayer();
    final third = ControlledNativePlayer();

    pool.park('a', first);
    pool.park('b', second);
    pool.park('c', third);

    expect(pool.keys, ['b', 'c']);
    await pool.releaseAll();
    expect(first.disposed, isTrue, reason: '被淘汰的条目必须释放');
  });

  test('同一个 key 再 park 会销毁被替换的播放器', () async {
    final pool = PlayerPool();
    final old = ControlledNativePlayer();
    final replacement = ControlledNativePlayer();

    pool.park('a', old);
    pool.park('a', replacement);

    expect(pool.length, 1);
    expect(pool.peek('a')?.player, same(replacement));
    await pool.releaseAll();
    expect(old.disposed, isTrue);
    expect(replacement.disposed, isTrue);
  });

  test('releaseAll 暂停并释放全部条目', () async {
    final pool = PlayerPool();
    final first = ControlledNativePlayer();
    final second = ControlledNativePlayer();
    pool.park('a', first);
    pool.park('b', second);

    await pool.releaseAll();

    expect(pool.isEmpty, isTrue);
    for (final player in [first, second]) {
      expect(player.disposed, isTrue);
      expect(player.calls, contains('pause'));
    }
  });

  test('dispose 之后 park 会立刻释放，不再留下条目', () async {
    final pool = PlayerPool();
    await pool.dispose();

    final player = ControlledNativePlayer();
    pool.park('a', player);

    expect(pool.isEmpty, isTrue);
    // 入池失败的那一个由 releaseAll 的队列负责销毁。
    await pool.releaseAll();
    expect(player.disposed, isTrue);
  });
}
