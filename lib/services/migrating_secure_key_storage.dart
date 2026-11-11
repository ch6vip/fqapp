import 'app_log.dart';
import 'secure_key_storage.dart';

/// Reads from [primary] and imports values that only exist in [legacy] on first
/// access, then writes them forward. Writes go to both stores so a rollback to
/// the previous build still finds the current key.
///
/// Presence is distinguished from failure on purpose: a *transient* primary
/// error with no legacy value is rethrown, because returning `null` there makes
/// `SecureKeyProvider` mint a brand-new key and quarantine the boxes encrypted
/// under the real one. Only "primary says absent, legacy says absent" creates a
/// key.
class MigratingSecureKeyStorage implements SecureKeyStorage {
  MigratingSecureKeyStorage({required this.primary, required this.legacy});

  final SecureKeyStorage primary;
  final SecureKeyStorage legacy;

  @override
  Future<String?> read(String key) async {
    Object? primaryError;
    try {
      final value = await primary.read(key);
      if (value != null) return value;
    } catch (error) {
      primaryError = error;
    }
    String? legacyValue;
    try {
      legacyValue = await legacy.read(key);
    } catch (_) {
      // Distinguish "legacy says nothing" from "legacy is broken": both land
      // here as no value, and the primary error below decides the outcome.
    }
    if (legacyValue == null) {
      if (primaryError != null) throw primaryError;
      return null;
    }
    try {
      await primary.write(key, legacyValue);
      AppLog.i('keys', '已将 $key 迁移到本机密钥库');
    } catch (error) {
      // Keep serving the legacy value; the next read retries the import.
      AppLog.w('keys', '迁移 $key 到本机密钥库失败：$error');
    }
    return legacyValue;
  }

  @override
  Future<void> write(String key, String value) async {
    await primary.write(key, value);
    try {
      await legacy.write(key, value);
    } catch (error) {
      // Dual-write is only a rollback aid; the native store already holds the
      // authoritative value.
      AppLog.w('keys', '同步 $key 到旧存储失败：$error');
    }
  }

  @override
  Future<void> delete(String key) async {
    await primary.delete(key);
    try {
      await legacy.delete(key);
    } catch (_) {
      // Same as write: best effort, the native store is authoritative.
    }
  }
}
