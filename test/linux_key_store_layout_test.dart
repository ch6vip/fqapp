import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/linux_libsecret_key_store.dart';

/// The Linux backend talks to libsecret through hand-written FFI. A wrong
/// struct layout would hand libsecret garbage pointers, and Linux has no CI
/// here, so at least the ABI sizes are pinned on every host we do run.
void main() {
  test('SecretSchema matches the libsecret 64-bit ABI', () {
    expect(LinuxLibsecretKeyStore.debugSecretSchemaSize, 592);
    expect(LinuxLibsecretKeyStore.debugSecretSchemaAttributeSize, 16);
  });
}
