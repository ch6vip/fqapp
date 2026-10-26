import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/drama_cache_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DramaCachePreferences.instance.resetForTest();
  });

  test('默认往后缓存 5 集，且只在 Wi-Fi 下跑', () async {
    final prefs = DramaCachePreferences.instance;
    await prefs.load();
    expect(prefs.ahead.value, 5);
    expect(prefs.wifiOnly.value, isTrue);
  });

  test('关掉后写回 0，重新加载仍是关', () async {
    final prefs = DramaCachePreferences.instance;
    await prefs.load();
    await prefs.setAhead(0);
    expect(prefs.ahead.value, 0);

    prefs.resetForTest();
    await prefs.load();
    expect(prefs.ahead.value, 0, reason: '关掉是持久化状态，不是会话态');
  });

  test('档位越界被夹住，脏数据不会让自动缓存失控', () async {
    final prefs = DramaCachePreferences.instance;
    await prefs.setAhead(999);
    expect(prefs.ahead.value, 50);
    await prefs.setAhead(-3);
    expect(prefs.ahead.value, 0);
  });

  test('下载画质选择持久化，默认最高', () async {
    final prefs = DramaCachePreferences.instance;
    await prefs.load();
    expect(prefs.downloadHeight.value, 0, reason: '默认不设上限');

    await prefs.setDownloadHeight(720);
    expect(prefs.downloadHeight.value, 720);

    prefs.resetForTest();
    await prefs.load();
    expect(prefs.downloadHeight.value, 720);
  });

  test('只读 Wi-Fi 开关也持久化', () async {
    final prefs = DramaCachePreferences.instance;
    await prefs.load();
    await prefs.setWifiOnly(false);
    expect(prefs.wifiOnly.value, isFalse);

    prefs.resetForTest();
    await prefs.load();
    expect(prefs.wifiOnly.value, isFalse);
  });
}
