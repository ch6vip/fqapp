import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Installs an in-memory handler for the native key store channel
/// (`fqapp/secure_keys`) and returns its backing map, so tests do not need a
/// real Keystore/Keychain and can assert what was persisted.
///
/// The store contract matches `SecureKeyPlugin` on Android and the Keychain
/// bridge on iOS: `read` returns the String or null, `write`/`delete` return
/// null.
Map<String, String> mockSecureKeyStorage([Map<String, String>? initial]) {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Platforms without a native backend (e.g. the macOS override some widget
  // tests use) fall back to the legacy package, so it needs a mock too.
  FlutterSecureStorage.setMockInitialValues(initial ?? {});
  final values = <String, String>{...?initial};
  const channel = MethodChannel('fqapp/secure_keys');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    final arguments = (call.arguments as Map).cast<String, Object?>();
    final key = arguments['key'] as String;
    switch (call.method) {
      case 'read':
        return values[key];
      case 'write':
        values[key] = arguments['value'] as String;
        return null;
      case 'delete':
        values.remove(key);
        return null;
    }
    throw MissingPluginException('${call.method} missing');
  });
  // No addTearDown: the helper is also used from setUpAll, where teardown
  // registration is not allowed, and each test file runs in its own isolate.
  return values;
}
