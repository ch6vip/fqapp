import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One explicit routing policy for the Rust core and its media clients.
class NetworkProxyConfig {
  const NetworkProxyConfig({this.enabled = false, this.url = ''});

  final bool enabled;
  final String url;

  Map<String, Object> toJson() => {'enabled': enabled, 'url': url.trim()};

  static String? validateUrl(String value) {
    final input = value.trim();
    final uri = Uri.tryParse(input);
    if (uri == null ||
        !{'http', 'https', 'socks5', 'socks5h'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        input.contains('%') ||
        !RegExp(r':\d+/?$').hasMatch(input) ||
        uri.port < 1 ||
        uri.port > 65535 ||
        RegExp(r'\s').hasMatch(input)) {
      return '请输入带协议和端口的代理地址，如 http://127.0.0.1:7890';
    }
    if (uri.userInfo.isNotEmpty || uri.authority.contains('@')) {
      return '请选择无需账号密码的代理端口';
    }
    if ((uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return '代理地址只填写协议、主机和端口';
    }
    return null;
  }
}

/// A single preference write keeps the mode and address consistent.
class NetworkProxyPreferences {
  NetworkProxyPreferences._();
  static final instance = NetworkProxyPreferences._();
  static const key = 'core_network_proxy_v1';

  Future<NetworkProxyConfig> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(key);
    if (raw == null) return const NetworkProxyConfig();
    final json = jsonDecode(raw);
    if (json is! Map || json['enabled'] is! bool || json['url'] is! String) {
      throw const FormatException('核心网络代理配置损坏，请重新保存');
    }
    final config = NetworkProxyConfig(
      enabled: json['enabled'] as bool,
      url: json['url'] as String,
    );
    _validate(config);
    return config;
  }

  Future<void> save(NetworkProxyConfig config) async {
    _validate(config);
    final sp = await SharedPreferences.getInstance();
    if (!await sp.setString(key, jsonEncode(config.toJson()))) {
      throw StateError('代理配置保存失败，请重试');
    }
  }

  static void _validate(NetworkProxyConfig config) {
    if (!config.enabled) return;
    final error = NetworkProxyConfig.validateUrl(config.url);
    if (error != null) throw FormatException(error);
  }
}
