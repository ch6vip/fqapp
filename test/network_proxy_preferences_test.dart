import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/services/network_proxy_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('missing preference selects explicit direct mode', () async {
    final config = await NetworkProxyPreferences.instance.load();
    expect(config.toJson(), {'enabled': false, 'url': ''});
  });

  test('saved proxy survives a fresh load and can be disabled', () async {
    final preferences = NetworkProxyPreferences.instance;
    await preferences.save(
      NetworkProxyConfig(enabled: true, url: 'http://127.0.0.1:7890'),
    );
    expect((await preferences.load()).toJson(), {
      'enabled': true,
      'url': 'http://127.0.0.1:7890',
    });
    await preferences.save(
      NetworkProxyConfig(enabled: false, url: 'http://127.0.0.1:7890'),
    );
    expect((await preferences.load()).enabled, isFalse);
    expect((await preferences.load()).url, 'http://127.0.0.1:7890');
  });

  test('accepts explicit ports, IPv6 and supported protocols', () {
    for (final url in [
      'http://localhost:80',
      'https://localhost:443',
      'socks5://127.0.0.1:1080',
      'socks5h://[::1]:1080',
    ]) {
      expect(NetworkProxyConfig.validateUrl(url), isNull, reason: url);
    }
  });

  test(
    'rejects ambiguous addresses, credentials and URL extras before saving',
    () async {
      for (final url in [
        '',
        '127.0.0.1:7890',
        'http://localhost',
        'ftp://localhost:21',
        'http://localhost:0',
        'http://localhost:65536',
        'http://u:p@localhost:7890',
        'http://localhost:7890/path',
        'http://localhost:7890?x=1',
        'http://localhost:7890#x',
        'http://[fe80::1%25Ethernet]:7890',
        'http://%6cocalhost:7890',
        'http://local\thost:7890',
        'http://local\nhost:7890',
      ]) {
        expect(NetworkProxyConfig.validateUrl(url), isNotNull, reason: url);
        await expectLater(
          NetworkProxyPreferences.instance.save(
            NetworkProxyConfig(enabled: true, url: url),
          ),
          throwsFormatException,
        );
      }
      expect((await NetworkProxyPreferences.instance.load()).enabled, isFalse);
    },
  );

  test(
    'corrupt stored proxy fails visibly instead of silently connecting directly',
    () async {
      SharedPreferences.setMockInitialValues({
        NetworkProxyPreferences.key: jsonEncode({
          'enabled': true,
          'url': 'invalid',
        }),
      });
      await expectLater(
        NetworkProxyPreferences.instance.load(),
        throwsFormatException,
      );
    },
  );
}
