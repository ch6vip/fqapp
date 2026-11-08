import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/local_proxy_discovery.dart';

void main() {
  test(
    'netstat uses listening loopback endpoints and normalizes wildcards',
    () {
      const output = '''
Active Connections
  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:18888          0.0.0.0:0              LISTENING       10
  TCP    127.0.0.1:1080         0.0.0.0:0              LISTENING       20
  TCP    [::]:18889            [::]:0                 LISTENING       30
  TCP    [::1]:1081            [::]:0                 LISTENING       40
  TCP    127.0.0.1:1080         0.0.0.0:0              LISTENING       20
  TCP    192.168.1.2:9000       0.0.0.0:0              LISTENING       50
  TCP    203.0.113.2:9001       0.0.0.0:0              LISTENING       60
  TCP    127.0.0.1:9002         127.0.0.1:1234         ESTABLISHED     70
  UDP    127.0.0.1:9003         *:*                                    80
  TCP    127.0.0.1:0            0.0.0.0:0              LISTENING       90
  TCP    [::1]:65536           [::]:0                 LISTENING       90
  TCP    garbage:88             0.0.0.0:0              LISTENING       90
''';
      expect(
        LocalProxyDiscovery.parseWindowsNetstat(
          output,
        ).map((endpoint) => endpoint.authority).toSet(),
        {'127.0.0.1:18888', '127.0.0.1:1080', '[::1]:18889', '[::1]:1081'},
      );
    },
  );

  test('discovers a real HTTP CONNECT tunnel on an arbitrary port', () async {
    final proxy = await _Server.start(_httpProxy);
    addTearDown(proxy.close);
    final results = await _discovery([proxy.endpoint]).discover();
    expect(results.map((candidate) => candidate.url), [
      'http://127.0.0.1:${proxy.port}',
    ]);
    expect(results.single.label, contains('HTTP'));
    expect(results.single.label, contains('127.0.0.1:${proxy.port}'));
  });

  test(
    'default Windows enumeration finds an arbitrary running proxy port',
    () async {
      if (!Platform.isWindows) return;
      final proxy = await _Server.start(_httpProxy);
      addTearDown(proxy.close);
      final results = await LocalProxyDiscovery().discover();
      expect(
        results.map((candidate) => candidate.url),
        contains('http://127.0.0.1:${proxy.port}'),
      );
    },
  );

  for (final ipv6 in [false, true]) {
    for (final boundType in [1, 3, 4]) {
      test(
        'SOCKS5 forwards fragmented origin token IPv6=$ipv6 BND=$boundType',
        () async {
          final proxy = await _Server.start(
            (socket, owner) => _socksProxy(socket, owner, boundType: boundType),
            ipv6: ipv6,
          );
          addTearDown(proxy.close);
          final results = await _discovery([proxy.endpoint]).discover();
          expect(results.map((candidate) => candidate.url), [
            ipv6
                ? 'socks5://[::1]:${proxy.port}'
                : 'socks5://127.0.0.1:${proxy.port}',
          ]);
          expect(results.single.label, contains('SOCKS5'));
        },
      );
    }
  }

  test('rejects SOCKS5 greeting success without CONNECT support', () async {
    final proxy = await _Server.start((socket, owner) async {
      await socket.first;
      socket.add([5, 0]);
      await socket.flush();
    });
    addTearDown(proxy.close);
    expect(await _discovery([proxy.endpoint]).discover(), isEmpty);
  });

  test('rejects SOCKS5 CONNECT failure after no-auth greeting', () async {
    final proxy = await _Server.start(
      (socket, owner) => _socksProxy(socket, owner, replyCode: 5),
    );
    addTearDown(proxy.close);
    expect(await _discovery([proxy.endpoint]).discover(), isEmpty);
  });

  test('rejects fake SOCKS5 CONNECT success without origin token', () async {
    final proxy = await _Server.start(
      (socket, owner) => _socksProxy(socket, owner, forward: false),
    );
    addTearDown(proxy.close);
    expect(await _discovery([proxy.endpoint]).discover(), isEmpty);
  });

  test('rejects SOCKS5 tunnel with incorrect token', () async {
    final proxy = await _Server.start(
      (socket, owner) => _socksProxy(socket, owner, wrongToken: true),
    );
    addTearDown(proxy.close);
    expect(await _discovery([proxy.endpoint]).discover(), isEmpty);
  });

  test('rejects SOCKS5 reply with unknown bound address type', () async {
    final proxy = await _Server.start(
      (socket, owner) => _socksProxy(socket, owner, boundType: 9),
    );
    addTearDown(proxy.close);
    expect(await _discovery([proxy.endpoint]).discover(), isEmpty);
  });

  test(
    'rejects ordinary HTTP, fake CONNECT success, echo and auth-only SOCKS',
    () async {
      final ordinary = await _Server.start((socket, owner) async {
        await socket.first;
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK');
        await socket.flush();
      });
      final fakeConnect = await _Server.start((socket, owner) async {
        await socket.first;
        socket.write('HTTP/1.1 200 Connection established\r\n\r\n');
        await socket.flush();
      });
      final echo = await _Server.start((socket, owner) async {
        await for (final bytes in socket) {
          socket.add(bytes);
          await socket.flush();
        }
      });
      final auth = await _Server.start((socket, owner) async {
        await socket.first;
        socket.add([5, 2]);
        await socket.flush();
      });
      for (final server in [ordinary, fakeConnect, echo, auth]) {
        addTearDown(server.close);
      }
      expect(
        await _discovery([
          ordinary.endpoint,
          fakeConnect.endpoint,
          echo.endpoint,
          auth.endpoint,
        ]).discover(),
        isEmpty,
      );
    },
  );

  test('deduplicates endpoints and returns stable URL order', () async {
    final first = await _Server.start(_httpProxy);
    final second = await _Server.start(_httpProxy);
    addTearDown(first.close);
    addTearDown(second.close);
    final expected = [
      'http://127.0.0.1:${first.port}',
      'http://127.0.0.1:${second.port}',
    ]..sort();
    final results = await _discovery([
      second.endpoint,
      first.endpoint,
      second.endpoint,
    ]).discover();
    expect(results.map((candidate) => candidate.url), expected);
  });

  test('bounds concurrency and closes stalled connections after timeout', () async {
    var active = 0;
    var peerPeak = 0;
    final releaseReads = Completer<void>();
    var receivedEof = 0;
    final allPeersClosed = Completer<void>();
    final tracker = _SocketTracker();
    final stalled = await _Server.start((socket, owner) async {
      active++;
      if (active > peerPeak) peerPeak = active;
      try {
        // Delay peer EOF consumption deterministically, as can happen under CI load.
        await releaseReads.future;
        await socket.drain<void>();
      } finally {
        active--;
        receivedEof++;
        if (receivedEof == tracker.connected) allPeersClosed.complete();
      }
    });
    addTearDown(stalled.close);
    // Different loopback addresses reach the same wildcard listener.
    final discovery = LocalProxyDiscovery(
      readListeners: () async => [
        for (var i = 1; i <= 6; i++)
          Uri(host: '127.0.0.$i', port: stalled.port),
      ],
      maxConcurrent: 2,
      timeout: const Duration(milliseconds: 20),
    );
    final clock = Stopwatch()..start();
    try {
      expect(await tracker.run(discovery.discover), isEmpty);
    } finally {
      releaseReads.complete();
    }
    expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    await allPeersClosed.future.timeout(const Duration(seconds: 3));
    // Remote EOF processing can lag behind local destroy; count the client's
    // connecting/open sockets for concurrency, and await each peer for cleanup.
    expect(tracker.attempts, 12);
    expect(tracker.peak, lessThanOrEqualTo(2));
    expect(tracker.active, 0);
    expect(tracker.connected, greaterThan(0));
    expect(receivedEof, tracker.connected);
    expect(peerPeak, greaterThan(2));
    expect(active, 0);
  });

  test('discovers IPv6 loopback HTTP proxy', () async {
    final proxy = await _Server.start(_httpProxy, ipv6: true);
    addTearDown(proxy.close);
    final results = await _discovery([proxy.endpoint]).discover();
    expect(results.map((candidate) => candidate.url), [
      'http://[::1]:${proxy.port}',
    ]);
  });

  test('ignores nonlocal endpoints before connecting', () async {
    expect(
      await _discovery([
        Uri(host: '203.0.113.1', port: 80),
        Uri(host: 'example.com', port: 80),
      ]).discover(),
      isEmpty,
    );
  });

  test('listener enumeration failures degrade to no candidates', () async {
    expect(
      await LocalProxyDiscovery(
        readListeners: () async => throw const ProcessException('netstat', []),
      ).discover(),
      isEmpty,
    );
  });
}

LocalProxyDiscovery _discovery(List<Uri> endpoints) => LocalProxyDiscovery(
  readListeners: () async => endpoints,
  timeout: const Duration(milliseconds: 250),
);

Future<void> _httpProxy(Socket socket, _Server owner) async {
  final input = StreamIterator<List<int>>(socket);
  final bytes = <int>[];
  try {
    while (await input.moveNext()) {
      bytes.addAll(input.current);
      // Close binary SOCKS greetings; this fixture is only an HTTP proxy.
      if (bytes.first == 5) return;
      if (!ascii.decode(bytes, allowInvalid: true).contains('\r\n\r\n')) {
        continue;
      }
      final line = ascii.decode(bytes).split('\r\n').first;
      final match = RegExp(
        r'^CONNECT (\[[^\]]+\]|[^: ]+):(\d+) HTTP/1\.[01]$',
      ).firstMatch(line);
      if (match == null) return;
      final host = match[1]!.replaceAll('[', '').replaceAll(']', '');
      // Test fixture also enforces that discovery never asks for an Internet target.
      if (!InternetAddress(host).isLoopback) {
        throw StateError('Nonlocal CONNECT: $line');
      }
      final upstream = await Socket.connect(host, int.parse(match[2]!));
      owner.sockets.add(upstream);
      socket.write('HTTP/1.1 200 Connection established\r\n\r\n');
      await socket.flush();
      await for (final data in upstream) {
        socket.add(data);
        await socket.flush();
      }
      return;
    }
  } finally {
    await input.cancel();
  }
}

Future<void> _socksProxy(
  Socket socket,
  _Server owner, {
  int boundType = 1,
  int replyCode = 0,
  bool forward = true,
  bool wrongToken = false,
}) async {
  final reader = _TestReader(socket);
  try {
    final greeting = await reader.read(3);
    if (greeting == null || greeting[0] != 5) return;
    expect(greeting, [5, 1, 0]);
    await _fragment(socket, [5, 0]);
    final header = await reader.read(4);
    if (header == null) return;
    expect(header.sublist(0, 3), [5, 1, 0]);
    expect(
      header[3],
      owner.server.address.type == InternetAddressType.IPv6 ? 4 : 1,
    );
    final rawAddress = await reader.read(header[3] == 4 ? 16 : 4);
    final rawPort = await reader.read(2);
    if (rawAddress == null || rawPort == null) return;
    final target = InternetAddress.fromRawAddress(
      Uint8List.fromList(rawAddress),
    );
    expect(target.isLoopback, isTrue);
    final port = rawPort[0] * 256 + rawPort[1];
    expect(port, greaterThan(0));
    final boundAddress = switch (boundType) {
      1 => [127, 0, 0, 1],
      3 => [9, ...ascii.encode('localhost')],
      4 => [...List.filled(15, 0), 1],
      _ => <int>[],
    };
    await _fragment(socket, [
      5,
      replyCode,
      0,
      boundType,
      ...boundAddress,
      0,
      80,
    ]);
    if (replyCode != 0 || boundType == 9) return;
    if (!forward) {
      await reader.read(
        1,
      ); // Wait for the discovery deadline to close the socket.
      return;
    }
    final upstream = await Socket.connect(target, port);
    owner.sockets.add(upstream);
    await for (final bytes in upstream) {
      await _fragment(
        socket,
        wrongToken ? List.filled(bytes.length, 120) : bytes,
      );
    }
  } finally {
    await reader.input.cancel();
  }
}

Future<void> _fragment(Socket socket, List<int> bytes) async {
  for (var offset = 0; offset < bytes.length; offset += 3) {
    final end = offset + 3 < bytes.length ? offset + 3 : bytes.length;
    socket.add(bytes.sublist(offset, end));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class _TestReader {
  _TestReader(Socket socket) : input = StreamIterator<List<int>>(socket);
  final StreamIterator<List<int>> input;
  final buffer = <int>[];

  Future<List<int>?> read(int length) async {
    while (buffer.length < length) {
      if (!await input.moveNext()) return null;
      buffer.addAll(input.current);
    }
    final bytes = buffer.sublist(0, length);
    buffer.removeRange(0, length);
    return bytes;
  }
}

class _SocketTracker {
  int active = 0;
  int peak = 0;
  int attempts = 0;
  int connected = 0;

  Future<T> run<T>(Future<T> Function() action) {
    final parent = Zone.current;
    return IOOverrides.runZoned(
      action,
      socketConnect:
          (
            dynamic host,
            int port, {
            dynamic sourceAddress,
            int sourcePort = 0,
            Duration? timeout,
          }) async {
            attempts++;
            active++;
            if (active > peak) peak = active;
            try {
              final socket = await parent.run(
                () => Socket.connect(
                  host,
                  port,
                  sourceAddress: sourceAddress,
                  sourcePort: sourcePort,
                  timeout: timeout,
                ),
              );
              connected++;
              return _TrackedSocket(socket, () => active--);
            } catch (_) {
              active--;
              rethrow;
            }
          },
    );
  }
}

// Instruments real client sockets; all network I/O still reaches the OS.
class _TrackedSocket extends Stream<Uint8List> implements Socket {
  _TrackedSocket(this.socket, this.onDestroy);
  final Socket socket;
  final void Function() onDestroy;
  bool destroyed = false;

  @override
  void destroy() {
    socket.destroy();
    if (!destroyed) {
      destroyed = true;
      onDestroy();
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => socket.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  void add(List<int> data) => socket.add(data);

  @override
  void write(Object? object) => socket.write(object);

  @override
  Future<void> flush() => socket.flush();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Server {
  _Server(this.server);
  final ServerSocket server;
  final sockets = <Socket>[];
  final handlers = <Future<void>>[];
  late final StreamSubscription<Socket> subscription;

  int get port => server.port;
  Uri get endpoint => Uri(
    host: server.address.type == InternetAddressType.IPv6 ? '::1' : '127.0.0.1',
    port: port,
  );

  static Future<_Server> start(
    Future<void> Function(Socket, _Server) handler, {
    bool ipv6 = false,
  }) async {
    final owner = _Server(
      await ServerSocket.bind(
        ipv6 ? InternetAddress.loopbackIPv6 : InternetAddress.anyIPv4,
        0,
        v6Only: ipv6,
      ),
    );
    owner.subscription = owner.server.listen((socket) {
      owner.sockets.add(socket);
      owner.handlers.add(() async {
        try {
          await handler(socket, owner);
        } on SocketException {
          // Discovery intentionally closes failed/timed out handshakes.
        } finally {
          socket.destroy();
        }
      }());
    });
    return owner;
  }

  Future<void> close() async {
    await subscription.cancel();
    await server.close();
    for (final socket in sockets) {
      socket.destroy();
    }
    await Future.wait(handlers);
  }
}
