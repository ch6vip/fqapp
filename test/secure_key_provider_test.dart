import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/secure_key_provider.dart';

/// The bootstrap awaits this provider during startup, so a secure-storage
/// call that never resolves must degrade (null) instead of hanging startup
/// forever — a wedged Keystore, or an unmocked platform channel in widget
/// tests, both present as a Future that never completes.
void main() {
  test('a never-resolving read degrades to null after the timeout', () async {
    final provider = SecureKeyProvider(
      storage: _HangingStorage(),
      storageTimeout: const Duration(milliseconds: 100),
    );
    final stopwatch = Stopwatch()..start();
    expect(await provider.getOrCreateKey(), isNull);
    expect(stopwatch.elapsedMilliseconds, lessThan(5000));
  });

  test('a failed load is cached: the next lookup returns null at once', () async {
    final provider = SecureKeyProvider(
      storage: _HangingStorage(),
      storageTimeout: const Duration(milliseconds: 100),
    );
    expect(await provider.getOrCreateKey(), isNull);
    final stopwatch = Stopwatch()..start();
    expect(await provider.getOrCreateKey(), isNull);
    // Would take another full timeout if the failure were not cached.
    expect(stopwatch.elapsedMilliseconds, lessThan(50));
  });

  test('a throwing store degrades to null', () async {
    final provider = SecureKeyProvider(
      storage: _ThrowingStorage(),
      storageTimeout: const Duration(milliseconds: 100),
    );
    expect(await provider.getOrCreateKey(), isNull);
  });

  test('a working store generates once and reuses the persisted key', () async {
    final storage = _MapStorage();
    final first = SecureKeyProvider(
      storage: storage,
      storageTimeout: const Duration(milliseconds: 100),
    );
    final key = await first.getOrCreateKey();
    expect(key, isNotNull);
    expect(key!.length, 32);
    expect(await first.getOrCreateKey(), same(key));

    // A fresh provider reads the persisted key instead of generating anew.
    final second = SecureKeyProvider(
      storage: storage,
      storageTimeout: const Duration(milliseconds: 100),
    );
    expect(await second.getOrCreateKey(), key);
  });
}

class _HangingStorage implements SecureKeyStorage {
  @override
  Future<String?> read(String key) => Completer<String?>().future;

  @override
  Future<void> write(String key, String value) =>
      Completer<void>().future;
}

class _ThrowingStorage implements SecureKeyStorage {
  @override
  Future<String?> read(String key) async => throw StateError('no keystore');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('no keystore');
}

class _MapStorage implements SecureKeyStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
