import 'dart:io';

import 'package:hive_ce/hive.dart';

import 'secure_key_provider.dart';

/// Opens every Hive box encrypted (hive_ce, AES-256 `HiveAesCipher`).
///
/// Layout: the encrypted box lives at `<name>_enc`; the legacy plaintext box
/// at `<name>` is only ever read for migration. Migration is crash-safe:
/// copy the legacy entries into the encrypted box (merging keys the
/// encrypted box is still missing after a crash), and only then delete the
/// legacy box. A crash mid-migration leaves the legacy box in place, so the
/// next launch retries instead of losing records.
///
/// Key loss: when secure storage returns a key that cannot open an existing
/// encrypted box (Keystore wiped, entry replaced), the unreadable box is
/// deleted and recreated empty — treated as empty, never silently downgraded
/// to plaintext. Callers that must never write plaintext pass
/// [requireEncryption]: when no key can be obtained at all (secure storage
/// unavailable) they fail closed instead of opening the legacy box.
///
/// The plaintext fallback is only for "no key *and* no encrypted box yet".
/// Finding an encrypted box with no available key also fails closed (see
/// [openBox]): opening the legacy box there would hide existing records
/// behind an empty one and write plaintext beside them.
class EncryptedHive {
  EncryptedHive._();

  /// Name of the encrypted box for a legacy box [name].
  static String encryptedBoxName(String name) => '${name}_enc';

  static bool isBoxOpen(HiveInterface hive, String name) =>
      hive.isBoxOpen(encryptedBoxName(name)) || hive.isBoxOpen(name);

  /// Whether the encrypted box is already on disk.
  ///
  /// Mirrors hive's own layout (`<homePath>/<lowercased name>.hive`, or its
  /// `.hivec`/`.lock` siblings) but is **synchronous on purpose**: this runs
  /// while local data is being initialized, and widget tests drive that inside
  /// a fake-async zone, where a real async file probe never completes
  /// (CRIT-014 in docs/规范/踩坑判据.md).
  static bool _encryptedBoxOnDisk(String encName) {
    if (Hive.isBoxOpen(encName)) return true;
    // `Hive` is typed as `HiveInterface`, which exposes no path accessor; the
    // concrete implementation that the global always is carries `homePath`.
    final home = (Hive as dynamic).homePath as String?;
    if (home == null || home.isEmpty) return false;
    final delimiter = Platform.isWindows ? '\\' : '/';
    final base = '$home$delimiter${encName.toLowerCase()}';
    return File('$base.hive').existsSync() ||
        File('$base.hivec').existsSync() ||
        File('$base.lock').existsSync();
  }

  /// The open box, preferring the encrypted one. Callers must check
  /// [isBoxOpen] first.
  static Box<E> box<E>(HiveInterface hive, String name) =>
      hive.isBoxOpen(encryptedBoxName(name))
      ? hive.box<E>(encryptedBoxName(name))
      : hive.box<E>(name);

  static Future<Box<E>> openBox<E>(
    HiveInterface hive,
    String name, {
    SecureKeyProvider? keys,
    bool requireEncryption = false,
    CompactionStrategy? compactionStrategy,
  }) async {
    // hive_ce's openBox takes a non-nullable compaction strategy (its
    // default is internal, so reproduce it here: compact once 15% of the
    // entries and at least 60 entries have been deleted).
    final strategy =
        compactionStrategy ??
        (int entries, int deleted) =>
            deleted > 60 && deleted / entries > 0.15;
    final encName = encryptedBoxName(name);
    if (hive.isBoxOpen(encName)) return hive.box<E>(encName);

    final key = await (keys ?? SecureKeyProvider.instance).getOrCreateKey();
    if (key == null) {
      if (requireEncryption) {
        throw StateError('加密密钥不可用，拒绝以明文打开 $name');
      }
      // An encrypted box already on disk means an earlier session did have a
      // key and the data is still there. Degrading to the legacy plaintext box
      // in that case shows an empty library, hides the real records, and starts
      // writing in parallel beside them - so fail closed instead. Callers sit
      // under a retryable bootstrap, so the user can retry once the key is
      // available and nothing is lost.
      if (_encryptedBoxOnDisk(encName)) {
        throw StateError('加密密钥不可用，而 $encName 已存在，拒绝以明文回落');
      }
      // Degraded path (tests, a first run before any key existed, a broken
      // Keystore with no encrypted data yet): plaintext legacy box, so the app
      // keeps working. Never used when a key is available.
      return hive.openBox<E>(name, compactionStrategy: strategy);
    }

    final cipher = HiveAesCipher(key);
    if (await hive.boxExists(encName)) {
      try {
        final box = await hive.openBox<E>(
          encName,
          encryptionCipher: cipher,
          compactionStrategy: strategy,
        );
        await _reconcileLegacy(hive, name, box);
        return box;
      } on HiveError catch (e) {
        if (!_looksLikeDecryptionFailure(e)) rethrow;
        // Key lost or encrypted file corrupt: treat the box as empty.
        await hive.deleteBoxFromDisk(encName);
      }
    }

    if (await hive.boxExists(name)) {
      final legacy = await hive.openBox<E>(name);
      final entries = <dynamic, dynamic>{};
      for (final legacyKey in legacy.keys) {
        entries[legacyKey] = legacy.get(legacyKey);
      }
      await legacy.close();
      final box = await hive.openBox<E>(
        encName,
        encryptionCipher: cipher,
        compactionStrategy: strategy,
      );
      if (entries.isNotEmpty) {
        await box.putAll(Map<dynamic, E>.from(entries));
      }
      await _reconcileLegacy(hive, name, box);
      return box;
    }

    return hive.openBox<E>(
      encName,
      encryptionCipher: cipher,
      compactionStrategy: strategy,
    );
  }

  /// Reconciles a leftover legacy box with the encrypted box.
  ///
  /// A crash between the copy and the delete can leave a partial encrypted
  /// box next to the full legacy box. Missing keys are copied from the
  /// legacy box (never overwriting: a key already present in the encrypted
  /// box may hold a newer write from after the migration started). Once
  /// every legacy key is present in the encrypted box, the legacy box is
  /// deleted; otherwise it is kept so the next launch can retry.
  static Future<void> _reconcileLegacy<E>(
    HiveInterface hive,
    String name,
    Box<E> encrypted,
  ) async {
    if (!await hive.boxExists(name)) return;
    final legacy = await hive.openBox<E>(name);
    try {
      final missing = <dynamic, dynamic>{};
      for (final key in legacy.keys) {
        if (!encrypted.containsKey(key)) {
          missing[key] = legacy.get(key);
        }
      }
      if (missing.isNotEmpty) {
        await encrypted.putAll(Map<dynamic, E>.from(missing));
      }
    } finally {
      await legacy.close();
    }
    await hive.deleteBoxFromDisk(name);
  }

  /// Only decryption failures may delete an encrypted box. Anything else
  /// (Hive not initialized, I/O errors) is rethrown so a transient failure
  /// can never look like a lost key and wipe user data.
  static bool _looksLikeDecryptionFailure(HiveError error) {
    final message = error.message.toLowerCase();
    return const [
      'checksum',
      'decrypt',
      'cipher',
      'corrupt',
      'authentication',
      'wrong key',
      'invalid key',
      'bad key',
      'tag mismatch',
      'mac mismatch',
    ].any(message.contains);
  }
}
