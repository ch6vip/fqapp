import 'package:flutter/foundation.dart';

import 'linux_libsecret_key_store.dart';
import 'migrating_secure_key_storage.dart';
import 'platform_channel.dart';
import 'secure_key_storage.dart';
import 'windows_dpapi_key_store.dart';

/// Platform-dispatching implementation of [SecureKeyStorage]:
///
/// | platform | backend |
/// |---|---|
/// | Android | `fqapp/secure_keys` → `SecureKeyPlugin` (AndroidKeyStore AES-GCM) |
/// | iOS | `fqapp/secure_keys` → Keychain (`SecureKeyPlugin.swift`) |
/// | Windows | DPAPI file, [WindowsDpapiKeyStore] |
/// | Linux | libsecret, [LinuxLibsecretKeyStore] |
///
/// This replaced `flutter_secure_storage` so the `win32` 5.x pin from
/// `flutter_secure_storage_windows 3.1.2` could leave the dependency graph
/// (#205). Key material never leaves the OS-protected store: nothing here
/// writes plaintext keys to preferences or to the app support directory.
class NativeSecureKeyStorage implements SecureKeyStorage {
  NativeSecureKeyStorage({
    SecureKeyStorage? mobile,
    SecureKeyStorage? windows,
    SecureKeyStorage? linux,
  }) : _backends = {
         TargetPlatform.android:
             mobile ?? const MethodChannelSecureKeyStorage(),
         TargetPlatform.iOS: mobile ?? const MethodChannelSecureKeyStorage(),
         TargetPlatform.windows: windows ?? WindowsDpapiKeyStore(),
         TargetPlatform.linux: linux ?? LinuxLibsecretKeyStore(),
       };

  final Map<TargetPlatform, SecureKeyStorage> _backends;

  /// Whether this build has an OS-backed store for the current platform.
  bool get isSupported => _backends.containsKey(defaultTargetPlatform);

  SecureKeyStorage get _backend =>
      _backends[defaultTargetPlatform] ??
      (throw UnsupportedError('本机密钥库不支持 ${defaultTargetPlatform.name}'));

  @override
  Future<String?> read(String key) => _backend.read(key);

  @override
  Future<void> write(String key, String value) => _backend.write(key, value);

  @override
  Future<void> delete(String key) => _backend.delete(key);
}

/// Mobile backend: one MethodChannel into the app's own Kotlin/Swift code, so
/// no third-party plugin is involved and the app module keeps compiling with
/// Built-in Kotlin.
class MethodChannelSecureKeyStorage implements SecureKeyStorage {
  const MethodChannelSecureKeyStorage();

  static const _channel = AppMethodChannel('fqapp/secure_keys');

  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', {'key': key});

  @override
  Future<void> write(String key, String value) =>
      _channel.invokeMethod<void>('write', {'key': key, 'value': value});

  @override
  Future<void> delete(String key) =>
      _channel.invokeMethod<void>('delete', {'key': key});
}

/// What the app uses in production: the native store, with the legacy
/// `flutter_secure_storage` entry imported (and re-written) on first read.
///
/// Platforms without a native backend (macOS/Fuchsia, which have no runner in
/// this repo) keep the legacy store rather than failing every key read. The
/// legacy side is a one-release import source; see
/// `DEVELOPMENT.md` →「本机密钥库」for the removal checklist.
SecureKeyStorage defaultSecureKeyStorage() {
  final native = NativeSecureKeyStorage();
  if (!native.isSupported) return const FlutterSecureKeyStorage();
  return MigratingSecureKeyStorage(
    primary: native,
    legacy: const FlutterSecureKeyStorage(),
  );
}
