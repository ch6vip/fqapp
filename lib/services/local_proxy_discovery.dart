import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class LocalProxyCandidate {
  const LocalProxyCandidate({required this.url, required this.label});

  final String url;
  final String label;
}

/// Discovers only when explicitly called; never changes system proxy settings.
class LocalProxyDiscovery {
  LocalProxyDiscovery({
    Future<List<Uri>> Function()? readListeners,
    this.maxConcurrent = 8,
    this.timeout = const Duration(milliseconds: 750),
  }) : _readListeners = readListeners ?? _systemListeners {
    if (maxConcurrent < 1 || maxConcurrent > 32) {
      throw ArgumentError.value(maxConcurrent, 'maxConcurrent', 'Must be 1–32');
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive');
    }
  }

  final Future<List<Uri>> Function() _readListeners;
  final int maxConcurrent;
  final Duration timeout;

  /// Windows wildcard listeners are probed through loopback, never public IPs.
  static List<Uri> parseWindowsNetstat(String output) {
    final endpoints = <String, Uri>{};
    for (final line in const LineSplitter().convert(output)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 4 ||
          fields[0].toUpperCase() != 'TCP' ||
          fields[3].toUpperCase() != 'LISTENING') {
        continue;
      }
      final address = fields[1];
      final colon = address.lastIndexOf(':');
      if (colon < 1) continue;
      final port = int.tryParse(address.substring(colon + 1));
      if (port == null) continue;
      final endpoint = _localEndpoint(address.substring(0, colon), port);
      if (endpoint != null) endpoints[endpoint.toString()] = endpoint;
    }
    return endpoints.values.toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));
  }

  Future<List<LocalProxyCandidate>> discover() async {
    final endpoints = <String, Uri>{};
    try {
      for (final listener in await _readListeners()) {
        final endpoint = _localEndpoint(listener.host, listener.port);
        if (endpoint != null) endpoints[endpoint.toString()] = endpoint;
      }
    } on Exception {
      return [];
    }
    if (endpoints.isEmpty) return [];

    // The token is sent only by our origin, never in the CONNECT request.
    // A normal web server or a fake "200 Connection established" cannot pass.
    final random = Random.secure();
    final token = ascii.encode(
      'fqapp-proxy-${base64UrlEncode(List.generate(24, (_) => random.nextInt(256)))}\n',
    );
    final origins = <InternetAddressType, _ProbeOrigin>{};
    final listeners = endpoints.values.toList();
    try {
      for (final type in listeners.map((e) => _address(e).type).toSet()) {
        try {
          origins[type] = await _ProbeOrigin.start(type, token, timeout);
        } on SocketException {
          // Both protocols require a reachable local origin to prove forwarding.
        }
      }
      final found = <LocalProxyCandidate>[];
      var next = 0;
      Future<void> worker() async {
        while (next < listeners.length) {
          final endpoint = listeners[next++];
          final origin = origins[_address(endpoint).type];
          if (origin == null) continue;
          if (await _probeSocks(endpoint, origin, token)) {
            found.add(_candidate('socks5', endpoint));
          }
          if (await _probeHttp(endpoint, origin, token)) {
            found.add(_candidate('http', endpoint));
          }
        }
      }

      await Future.wait(
        List.generate(min(maxConcurrent, listeners.length), (_) => worker()),
      );
      return found..sort((a, b) => a.url.compareTo(b.url));
    } finally {
      await Future.wait(origins.values.map((origin) => origin.close()));
    }
  }

  Future<bool> _probeSocks(
    Uri endpoint,
    _ProbeOrigin origin,
    List<int> token,
  ) => _withSocket(endpoint, (socket, reader) async {
    socket.add([5, 1, 0]);
    await socket.flush();
    final method = await reader.readBytes(2);
    if (method[0] != 5 || method[1] != 0) return false;

    final address = origin.server.address;
    final port = origin.server.port;
    socket.add([
      5,
      1,
      0,
      address.type == InternetAddressType.IPv6 ? 4 : 1,
      ...address.rawAddress,
      port >> 8,
      port & 255,
    ]);
    await socket.flush();
    final reply = await reader.readBytes(4);
    if (reply[0] != 5 || reply[1] != 0 || reply[2] != 0) return false;
    final int boundLength;
    switch (reply[3]) {
      case 1:
        boundLength = 4;
      case 4:
        boundLength = 16;
      case 3:
        boundLength = (await reader.readBytes(1)).single;
        if (boundLength == 0) return false;
      default:
        return false;
    }
    await reader.readBytes(boundLength + 2);
    final forwarded = await reader.readBytes(token.length);
    for (var i = 0; i < token.length; i++) {
      if (forwarded[i] != token[i]) return false;
    }
    return true;
  });

  Future<bool> _probeHttp(Uri endpoint, _ProbeOrigin origin, List<int> token) =>
      _withSocket(endpoint, (socket, reader) async {
        final authority = Uri(
          host: origin.server.address.address,
          port: origin.server.port,
        ).authority;
        socket.write(
          'CONNECT $authority HTTP/1.1\r\n'
          'Host: $authority\r\n'
          'Connection: close\r\n\r\n',
        );
        await socket.flush();
        final header = ascii.decode(
          await reader.readHeader(),
          allowInvalid: true,
        );
        if (!RegExp(r'^HTTP/1\.[01] 200(?: |\r\n|$)').hasMatch(header)) {
          return false;
        }
        final reply = await reader.readBytes(token.length);
        for (var i = 0; i < token.length; i++) {
          if (reply[i] != token[i]) return false;
        }
        return true;
      });

  Future<bool> _withSocket(
    Uri endpoint,
    Future<bool> Function(Socket, _SocketReader) handshake,
  ) async {
    Socket? socket;
    _SocketReader? reader;
    try {
      socket = await Socket.connect(
        _address(endpoint),
        endpoint.port,
        timeout: timeout,
      );
      reader = _SocketReader(socket);
      return await handshake(socket, reader).timeout(timeout);
    } on Exception {
      return false;
    } finally {
      socket?.destroy();
      await reader?.cancel();
    }
  }

  static InternetAddress _address(Uri endpoint) =>
      InternetAddress(endpoint.host.replaceAll('[', '').replaceAll(']', ''));

  static Uri? _localEndpoint(String host, int port) {
    if (port < 1 || port > 65535) return null;
    host = host.replaceAll('[', '').replaceAll(']', '');
    if (host == '0.0.0.0') host = '127.0.0.1';
    if (host == '::') host = '::1';
    final address = InternetAddress.tryParse(host);
    if (address == null || !address.isLoopback) return null;
    return Uri(host: address.address, port: port);
  }

  static LocalProxyCandidate _candidate(String scheme, Uri endpoint) {
    final url = Uri(
      scheme: scheme,
      host: endpoint.host,
      port: endpoint.port,
    ).toString();
    final protocol = scheme == 'http' ? 'HTTP' : 'SOCKS5';
    return LocalProxyCandidate(
      url: url,
      label: '$protocol · ${endpoint.authority}',
    );
  }

  static Future<List<Uri>> _systemListeners() async {
    if (!Platform.isWindows) return const [];
    final process = await Process.start('netstat', ['-ano', '-p', 'tcp']);
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final errors = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final result = await Future.wait<Object>([
        output,
        errors,
        process.exitCode,
      ]).timeout(const Duration(seconds: 3));
      if (result[2] != 0) {
        throw ProcessException('netstat', [
          '-ano',
          '-p',
          'tcp',
        ], result[1] as String);
      }
      return parseWindowsNetstat(result[0] as String);
    } finally {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 1),
        onTimeout: () => -1,
      );
    }
  }
}

class _SocketReader {
  _SocketReader(Socket socket) : _input = StreamIterator<List<int>>(socket);
  final StreamIterator<List<int>> _input;
  final _buffer = <int>[];

  Future<void> _more() async {
    if (!await _input.moveNext()) {
      throw const FormatException('Incomplete proxy reply');
    }
    _buffer.addAll(_input.current);
    if (_buffer.length > 16384) {
      throw const FormatException('Proxy reply too large');
    }
  }

  Future<List<int>> readBytes(int count) async {
    while (_buffer.length < count) {
      await _more();
    }
    final bytes = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return bytes;
  }

  Future<List<int>> readHeader() async {
    while (true) {
      for (var i = 0; i + 3 < _buffer.length; i++) {
        if (_buffer[i] == 13 &&
            _buffer[i + 1] == 10 &&
            _buffer[i + 2] == 13 &&
            _buffer[i + 3] == 10) {
          final header = _buffer.sublist(0, i);
          _buffer.removeRange(0, i + 4);
          return header;
        }
      }
      await _more();
    }
  }

  Future<void> cancel() => _input.cancel();
}

class _ProbeOrigin {
  _ProbeOrigin(this.server);
  final ServerSocket server;
  final _sockets = <Socket>{};
  final _tasks = <Future<void>>[];
  late final StreamSubscription<Socket> _subscription;

  static Future<_ProbeOrigin> start(
    InternetAddressType type,
    List<int> token,
    Duration timeout,
  ) async {
    final ipv6 = type == InternetAddressType.IPv6;
    final origin = _ProbeOrigin(
      await ServerSocket.bind(
        ipv6 ? InternetAddress.loopbackIPv6 : InternetAddress.loopbackIPv4,
        0,
        v6Only: ipv6,
      ),
    );
    origin._subscription = origin.server.listen((socket) {
      origin._sockets.add(socket);
      origin._tasks.add(() async {
        try {
          socket.add(token);
          await socket.flush().timeout(timeout);
        } on Exception {
          // Probe deadlines can close the tunnel while the origin is flushing.
        } finally {
          socket.destroy();
          origin._sockets.remove(socket);
        }
      }());
    });
    return origin;
  }

  Future<void> close() async {
    await _subscription.cancel();
    await server.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
    await Future.wait(_tasks);
  }
}
