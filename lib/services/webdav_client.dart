import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class WebDavException implements Exception {
  const WebDavException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WebDavConfig {
  const WebDavConfig({
    required this.directory,
    required this.username,
    required this.password,
    required this.enabled,
  });
  final String directory;
  final String username;
  final String password;
  final bool enabled;

  Uri get fileUri {
    final uri = Uri.tryParse(directory.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const WebDavException('请输入 HTTPS WebDAV 目录地址，不要包含账号、查询参数或片段');
    }
    return uri.replace(
      path:
          '${uri.path.endsWith('/') ? uri.path : '${uri.path}/'}fqapp-sync.json',
    );
  }

  Map<String, dynamic> toJson() => {
    'directory': directory,
    'username': username,
    'password': password,
    'enabled': enabled,
  };

  factory WebDavConfig.fromJson(Map<String, dynamic> json) => WebDavConfig(
    directory: json['directory'] as String,
    username: json['username'] as String,
    password: json['password'] as String,
    enabled: json['enabled'] == true,
  );
}

class WebDavRemote {
  const WebDavRemote(this.bytes, this.etag);
  final Uint8List? bytes;
  final String? etag;
}

/// Conditional PUT prevents one device from silently replacing another's edit.
/// Redirects are deliberately not followed with the Authorization header.
class WebDavClient {
  WebDavClient(this.config, {http.Client? client})
    : _client = client ?? http.Client();
  final WebDavConfig config;
  final http.Client _client;
  static const maxBytes = 20 * 1024 * 1024;

  Future<http.Response> _request(
    String method, {
    Uint8List? bytes,
    Map<String, String> headers = const {},
    Uri? uri,
  }) async {
    final request = http.Request(method, uri ?? config.fileUri)
      ..followRedirects = false
      ..headers.addAll({
        // Compression proxies can weaken ETags; conditional PUT needs the
        // validator for the original representation.
        'accept-encoding': 'identity',
        'authorization':
            'Basic ${base64Encode(utf8.encode('${config.username}:${config.password}'))}',
        ...headers,
      });
    if (bytes != null) request.bodyBytes = bytes;
    try {
      return await (() async {
        final response = await _client.send(request);
        if ((response.contentLength ?? 0) > maxBytes) {
          throw const WebDavException('同步文件超过 20 MB');
        }
        final body = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (body.length + chunk.length > maxBytes) {
            throw const WebDavException('同步文件超过 20 MB');
          }
          body.add(chunk);
        }
        return http.Response.bytes(
          body.takeBytes(),
          response.statusCode,
          headers: response.headers,
        );
      })().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const WebDavException('WebDAV 请求超时，请检查网络后重试');
    } on http.ClientException {
      throw const WebDavException('无法连接 WebDAV，请检查地址和网络');
    }
  }

  Never _fail(int status) => throw WebDavException(switch (status) {
    401 || 403 => 'WebDAV 认证失败或没有读写权限',
    301 || 302 || 307 || 308 => 'WebDAV 地址发生重定向，请填写最终目录地址',
    404 || 409 => 'WebDAV 目录不存在，请先在服务器创建目录',
    507 => 'WebDAV 存储空间不足',
    _ => 'WebDAV 请求失败（HTTP $status）',
  });

  Future<WebDavRemote> read() async {
    final response = await _request('GET');
    if (response.statusCode == 404) return const WebDavRemote(null, null);
    if (response.statusCode != 200) _fail(response.statusCode);
    final etag = response.headers['etag'];
    if (etag == null ||
        etag.startsWith('W/') ||
        !etag.startsWith('"') ||
        !etag.endsWith('"')) {
      throw const WebDavException('服务器未提供强 ETag，无法安全进行多设备同步');
    }
    return WebDavRemote(response.bodyBytes, etag);
  }

  /// False means another device won this write; re-read and merge before retry.
  Future<bool> write(Uint8List bytes, String? etag) async {
    if (bytes.length > maxBytes) throw const WebDavException('同步文件超过 20 MB');
    var response = await _request(
      'PUT',
      bytes: bytes,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        if (etag == null) 'if-none-match': '*' else 'if-match': etag,
      },
    );
    if (response.statusCode == 409 || response.statusCode == 404) {
      final directory = config.fileUri.resolve('.');
      var path = '';
      for (final segment in directory.pathSegments.where((s) => s.isNotEmpty)) {
        path += '/${Uri.encodeComponent(segment)}';
        final created = await _request(
          'MKCOL',
          uri: directory.replace(path: '$path/'),
        );
        if (![200, 201, 204, 405].contains(created.statusCode)) {
          _fail(created.statusCode);
        }
      }
      response = await _request(
        'PUT',
        bytes: bytes,
        headers: {
          'content-type': 'application/json; charset=utf-8',
          if (etag == null) 'if-none-match': '*' else 'if-match': etag,
        },
      );
    }
    if (response.statusCode == 412) return false;
    if (![200, 201, 204].contains(response.statusCode)) {
      _fail(response.statusCode);
    }
    return true;
  }

  void close() => _client.close();
}
