import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/request_gate.dart';

void main() {
  test('identical concurrent flights share one send', () async {
    final gate = RequestGate();
    var sends = 0;
    final results = await Future.wait([
      gate.run<String>('GET /a', send: () async {
        sends++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 'a';
      }),
      gate.run<String>('GET /a', send: () async {
        sends++;
        return 'a-should-not-run';
      }),
    ]);
    expect(sends, 1);
    expect(results, ['a', 'a']);
  });

  test('different keys never share', () async {
    final gate = RequestGate();
    final sends = <String>[];
    await Future.wait([
      gate.run<String>('GET /a', send: () async {
        sends.add('a');
        return 'a';
      }),
      gate.run<String>('GET /b', send: () async {
        sends.add('b');
        return 'b';
      }),
    ]);
    expect(sends, unorderedEquals(['a', 'b']));
  });

  test('the cap queues excess work instead of starting it', () async {
    final gate = RequestGate(maxConcurrent: 2);
    final started = <int>[];
    final flights = [
      for (var i = 0; i < 4; i++)
        gate.run<String>(
          'GET /item-$i',
          send: () async {
            started.add(i);
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return 'item-$i';
          },
        ),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 1));
    // The cap holds two; the rest are queued, not started.
    expect(started.length, 2);
    final results = await Future.wait(flights);
    expect(results.length, 4);
    expect(started.length, 4);
  });

  test('a cancelled queued caller fails fast and never sends', () async {
    final gate = RequestGate(maxConcurrent: 1);
    final blocker = Completer<String>();
    final request = BackendRequest();
    final occupied = gate.run<String>('GET /x', send: () => blocker.future);
    final queued = gate.run<String>(
      'GET /y',
      send: () async => 'should-not-run',
      request: request,
    );
    await Future<void>.delayed(Duration.zero);
    request.cancel();
    await expectLater(queued, throwsA(isA<BackendRequestAborted>()));
    // Slot accounting must be intact: unblock and the gate still works.
    blocker.complete('done');
    expect(await occupied, 'done');
    expect(await gate.run<String>('GET /z', send: () async => 'z'), 'z');
  });

  test('a joiner survives the owner being cancelled', () async {
    final gate = RequestGate();
    final owner = BackendRequest();
    final joiner = BackendRequest();
    final ownerCancelled = Completer<String>();
    var secondSend = false;
    final shared = gate.run<String>(
      'GET /shared',
      send: () => ownerCancelled.future,
      request: owner,
    );
    final joined = gate.run<String>(
      'GET /shared',
      send: () async {
        secondSend = true;
        return 'own-result';
      },
      request: joiner,
    );
    await Future<void>.delayed(Duration.zero);
    owner.cancel();
    ownerCancelled.completeError(BackendRequestAborted('请求已取消'));
    expect(await joined, 'own-result');
    expect(secondSend, isTrue);
    await expectLater(shared, throwsA(isA<BackendRequestAborted>()));
  });

  test('a cancelled joiner stops waiting without aborting its owner', () async {
    final gate = RequestGate();
    final ownerResult = Completer<String>();
    final joinerRequest = BackendRequest();
    var joinerSends = 0;
    final owner = gate.run<String>(
      'GET /shared',
      send: () => ownerResult.future,
    );
    final joiner = gate.run<String>(
      'GET /shared',
      request: joinerRequest,
      send: () async {
        joinerSends++;
        return 'unexpected';
      },
    );

    joinerRequest.cancel();
    await expectLater(
      joiner.timeout(const Duration(seconds: 1)),
      throwsA(isA<BackendRequestAborted>()),
    );
    expect(joinerSends, 0);
    ownerResult.complete('owner-result');
    expect(await owner, 'owner-result');
  });

  test('a cancellation at grant does not send or release twice', () async {
    final gate = RequestGate(maxConcurrent: 1);
    final blocker = Completer<String>();
    final request = BackendRequest();
    var cancelledSends = 0;
    final occupied = gate.run<String>('GET /owner', send: () => blocker.future);
    final cancelled = gate.run<String>(
      'GET /cancelled',
      request: request,
      send: () async {
        cancelledSends++;
        return 'unexpected';
      },
    );
    // The owner's result is published before it grants the waiting slot. Its
    // listener cancels the waiter after the grant and before it resumes.
    occupied.then((_) => request.cancel());
    blocker.complete('done');
    expect(await occupied, 'done');
    await expectLater(cancelled, throwsA(isA<BackendRequestAborted>()));
    expect(cancelledSends, 0);

    final next = Completer<String>();
    var followingSends = 0;
    final running = gate.run<String>('GET /next', send: () => next.future);
    final following = gate.run<String>(
      'GET /following',
      send: () async {
        followingSends++;
        return 'following';
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(followingSends, 0);
    next.complete('next');
    expect(await running, 'next');
    expect(await following, 'following');
  });

  test('a cancelled caller never joins or sends', () async {
    final gate = RequestGate();
    final request = BackendRequest()..cancel();
    await expectLater(
      gate.run<String>(
        'GET /a',
        send: () async => 'should-not-run',
        request: request,
      ),
      throwsA(isA<BackendRequestAborted>()),
    );
  });
}
