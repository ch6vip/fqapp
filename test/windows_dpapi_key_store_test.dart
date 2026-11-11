@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/windows_dpapi_key_store.dart';

/// Real DPAPI round trip: no mocks, because the whole point of replacing
/// `flutter_secure_storage_windows` is that another Windows user (or a copied
/// file) must not be able to read the keys. Only runs on a Windows host.
void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('fqapp-dpapi-');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  WindowsDpapiKeyStore open() =>
      WindowsDpapiKeyStore(directory: () async => directory);

  File mainFile() =>
      File('${directory.path}${Platform.pathSeparator}secure_keys.dpapi');

  test('round-trips keys and keeps plaintext off disk', () async {
    final store = open();
    await store.write('fqapp_hive_encryption_key_v1', 'value-a');
    await store.write('fqapp_device_pool_key_v1', 'value-b');

    final bytes = mainFile().readAsBytesSync();
    expect(bytes, isNotEmpty);
    final asText = utf8.decode(bytes, allowMalformed: true);
    expect(asText, isNot(contains('value-a')));
    expect(asText, isNot(contains('fqapp_hive_encryption_key_v1')));

    // A fresh instance reads from disk, so DPAPI (not the in-memory cache) is
    // what the next launch depends on.
    final reopened = open();
    expect(await reopened.read('fqapp_hive_encryption_key_v1'), 'value-a');
    expect(await reopened.read('fqapp_device_pool_key_v1'), 'value-b');
    expect(await reopened.read('missing'), isNull);
  });

  test('delete removes one entry and keeps the rest', () async {
    final store = open();
    await store.write('a', '1');
    await store.write('b', '2');
    await store.delete('a');

    final reopened = open();
    expect(await reopened.read('a'), isNull);
    expect(await reopened.read('b'), '2');
  });

  test('an interrupted write still leaves the previous keys readable', () async {
    final store = open();
    await store.write('a', '1');
    await store.write('b', '2');
    final backup = File('${mainFile().path}.bak');
    expect(backup.existsSync(), isTrue);

    // Simulate a crash between "rotate main to .bak" and "rename temp to main".
    mainFile().deleteSync();
    final reopened = open();
    expect(await reopened.read('a'), '1');
  });

  test('a corrupted blob throws instead of looking absent', () async {
    final store = open();
    await store.write('a', '1');
    mainFile().writeAsBytesSync([1, 2, 3, 4, 5]);

    // WindowsDpapiException (or FormatException) — either way the provider must
    // see a failure, not an empty map it would replace with a new key.
    expect(open().read('a'), throwsA(anything));
  });

  test('no file means no keys', () async {
    expect(await open().read('a'), isNull);
    expect(mainFile().existsSync(), isFalse);
  });
}
