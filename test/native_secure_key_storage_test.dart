import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/migrating_secure_key_storage.dart';
import 'package:fqapp/services/native_secure_key_storage.dart';
import 'package:fqapp/services/secure_key_provider.dart';

/// Which backend a platform gets, and what happens where this repo has no
/// runner (macOS/Fuchsia): keys must keep working through the legacy store
/// rather than failing every read.
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    test('${platform.name} imports legacy keys into the native store', () {
      debugDefaultTargetPlatformOverride = platform;
      final storage = defaultSecureKeyStorage();
      expect(storage, isA<MigratingSecureKeyStorage>());
      expect(
        (storage as MigratingSecureKeyStorage).primary,
        isA<NativeSecureKeyStorage>(),
      );
    });
  }

  test('a platform without a backend keeps the legacy store', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(defaultSecureKeyStorage(), isA<FlutterSecureKeyStorage>());
  });
}
