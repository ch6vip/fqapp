import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fqapp/services/app_theme_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(SharedPreferences.resetStatic);

  test('missing and malformed theme keep archive without writing', () async {
    for (final value in <Object?>[null, 'future-theme', 3, false]) {
      SharedPreferences.setMockInitialValues({
        AppThemeStyleStore.storageKey: ?value,
      });
      final store = AppThemeStyleStore();
      await store.load();
      expect(store.value, AppThemeStyle.archive);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.get(AppThemeStyleStore.storageKey), value);
      store.dispose();
    }
  });

  test('selection saves and is restored by a fresh store', () async {
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final saved = store.select(AppThemeStyle.classic);
    expect(store.value, AppThemeStyle.classic);
    expect(await saved, isTrue);
    final restored = AppThemeStyleStore();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.value, AppThemeStyle.classic);
  });

  test('late startup read cannot replace a newer user selection', () async {
    SharedPreferences.setMockInitialValues({
      AppThemeStyleStore.storageKey: 'classic',
    });
    final prefs = await SharedPreferences.getInstance();
    final gate = Completer<SharedPreferences>();
    final store = AppThemeStyleStore(preferences: () => gate.future);
    addTearDown(store.dispose);
    final loading = store.load();
    expect(store.load(), same(loading));
    final saved = store.select(AppThemeStyle.archive);
    gate.complete(prefs);
    await loading;
    expect(await saved, isTrue);
    expect(store.value, AppThemeStyle.archive);
    expect(prefs.getString(AppThemeStyleStore.storageKey), 'archive');
  });

  test('rapid selections serialize writes and keep the last choice', () async {
    final platform = _GatedWrites();
    SharedPreferencesStorePlatform.instance = platform;
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    final first = store.select(AppThemeStyle.classic);
    await platform.firstStarted.future;
    final second = store.select(AppThemeStyle.archive);
    expect(store.value, AppThemeStyle.archive);
    expect(platform.values, ['classic']);
    platform.release.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(platform.values, ['classic', 'archive']);
    SharedPreferences.resetStatic();
    final restored = AppThemeStyleStore();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.value, AppThemeStyle.archive);
  });

  test('failed save keeps session choice and later retry succeeds', () async {
    final platform = _FailOnce();
    SharedPreferencesStorePlatform.instance = platform;
    final store = AppThemeStyleStore();
    addTearDown(store.dispose);
    expect(await store.select(AppThemeStyle.classic), isFalse);
    expect(store.value, AppThemeStyle.classic);
    expect(await store.select(AppThemeStyle.classic), isTrue);
    SharedPreferences.resetStatic();
    final restored = AppThemeStyleStore();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.value, AppThemeStyle.classic);
  });

  test(
    'read failure is optional and can retry without changing data',
    () async {
      var reads = 0;
      SharedPreferences.setMockInitialValues({
        AppThemeStyleStore.storageKey: 'classic',
      });
      final store = AppThemeStyleStore(
        preferences: () async {
          if (++reads == 1) throw StateError('test read failure');
          return SharedPreferences.getInstance();
        },
      );
      addTearDown(store.dispose);
      await store.load();
      expect(store.value, AppThemeStyle.archive);
      await store.load();
      expect(store.value, AppThemeStyle.classic);
    },
  );

  test(
    'theme changes never write brightness, reader or shelf preferences',
    () async {
      const existing = {
        'shelfLayout': 'shelfGrid',
        'shelfGridDensity': 'small',
        'theme_mode': 'dark',
        'oled_mode': true,
        'eink_mode': false,
        'reader_theme': 'parchment',
        'reader_font_size': 23.0,
      };
      SharedPreferences.setMockInitialValues(existing);
      final store = AppThemeStyleStore();
      addTearDown(store.dispose);
      await store.load();
      await store.select(AppThemeStyle.classic);
      final prefs = await SharedPreferences.getInstance();
      for (final entry in existing.entries) {
        expect(prefs.get(entry.key), entry.value);
      }
      expect(prefs.getKeys(), {
        ...existing.keys,
        AppThemeStyleStore.storageKey,
      });
    },
  );
}

class _GatedWrites extends InMemorySharedPreferencesStore {
  _GatedWrites() : super.withData({});

  final firstStarted = Completer<void>();
  final release = Completer<void>();
  final values = <Object>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    values.add(value);
    if (values.length == 1) {
      firstStarted.complete();
      await release.future;
    }
    return super.setValue(valueType, key, value);
  }
}

class _FailOnce extends InMemorySharedPreferencesStore {
  _FailOnce() : super.withData({});
  bool failed = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!failed) {
      failed = true;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}
