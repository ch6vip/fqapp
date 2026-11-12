import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/linux_libsecret_key_store.dart';

/// The Linux backend talks to libsecret through hand-written FFI. A wrong
/// struct layout or a symbol loaded from the wrong library breaks key access.
void main() {
  test('SecretSchema matches the libsecret 64-bit ABI', () {
    expect(LinuxLibsecretKeyStore.debugSecretSchemaSize, 592);
    expect(LinuxLibsecretKeyStore.debugSecretSchemaAttributeSize, 16);
  });

  test(
    'Linux libraries provide all production FFI bindings',
    () => expect(
      LinuxLibsecretKeyStore.debugValidateNativeBindings,
      returnsNormally,
    ),
    skip: !Platform.isLinux,
  );
}
