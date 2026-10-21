import 'package:hive_ce/hive.dart';

import 'app_log.dart';
import 'secure_key_provider.dart';

/// 一次性迁移：把加密存储时代（v1.0.121 起的 P1-3 加密箱）落盘的
/// `<name>_enc` 加密箱搬回同名明文箱。
///
/// 加密层已整体撤销：个别机型的 Android Keystore 读不到密钥时，
/// fail-closed 会把启动直接锁死在「无法读取本地数据」。各 store 现在
/// 直接开明文箱，本迁移只负责把老用户的加密数据原样搬出来。
///
/// 安全边界（任何一条不满足都只跳过该箱，绝不抛错、绝不阻塞启动）：
/// - 只读已有密钥：取不到密钥（安全存储不可用 / 从没建过）就跳过，
///   `_enc` 文件原样保留，绝不在迁移里新建密钥。
/// - 密钥对不上（解不开加密箱）同样跳过并保留原文件，不删数据。
/// - 复制只补明文箱缺失的键（明文箱可能有降级期间写入的更新记录，
///   不覆盖）；校验加密箱的键在明文箱中全部存在后，才删除加密箱。
/// - 幂等：迁移完成的箱子 `_enc` 已删除，下次启动直接跳过；中途
///   失败保留 `_enc`，下次启动重试缺失部分。
class EncryptedBoxMigration {
  EncryptedBoxMigration._();

  /// 加密时代所有经 EncryptedHive 打开过的箱名（与各 store 的箱名
  /// 常量对应：library 的 history/read_time/watched_episodes、
  /// shelf、digg、guide、reader_underlines_v1、home_feed_cache_v1、
  /// rank_cache_v1、chapter_cache_v1、drama_download_v1、
  /// audio_download_v1）。
  static const List<String> boxNames = [
    'history',
    'read_time',
    'watched_episodes',
    'shelf',
    'digg',
    'guide',
    'reader_underlines_v1',
    'home_feed_cache_v1',
    'rank_cache_v1',
    'chapter_cache_v1',
    'drama_download_v1',
    'audio_download_v1',
  ];

  /// 在 Hive.initFlutter 之后、各 store 初始化之前运行。整体不抛错。
  static Future<void> migrateAll(
    HiveInterface hive, {
    SecureKeyProvider? keys,
  }) async {
    final provider = keys ?? SecureKeyProvider.instance;
    for (final name in boxNames) {
      await _migrateBox(hive, name, provider);
    }
  }

  static Future<void> _migrateBox(
    HiveInterface hive,
    String name,
    SecureKeyProvider keys,
  ) async {
    final encName = '${name}_enc';
    try {
      if (!await hive.boxExists(encName)) return;

      final key = await keys.readExistingKey();
      if (key == null) {
        // 取不到已有密钥：保留加密箱原样，等密钥可读的启动再迁。
        AppLog.w('enc-migration', '无可用密钥，跳过 $encName 的明文迁移');
        return;
      }

      Box<dynamic> enc;
      try {
        enc = await hive.openBox<dynamic>(
          encName,
          encryptionCipher: HiveAesCipher(key),
        );
      } on HiveError catch (e, st) {
        // 密钥与箱子对不上或箱体损坏：保留原文件，不当作空箱删除。
        AppLog.e('enc-migration', '加密箱 $encName 打不开，保留原文件', error: e, stack: st);
        return;
      }

      try {
        final plain = await hive.openBox<dynamic>(name);
        try {
          final pending = <dynamic, dynamic>{};
          for (final entryKey in enc.keys) {
            if (!plain.containsKey(entryKey)) {
              pending[entryKey] = enc.get(entryKey);
            }
          }
          if (pending.isNotEmpty) {
            await plain.putAll(pending);
          }
          if (!enc.keys.every(plain.containsKey)) {
            AppLog.e('enc-migration', '迁移 $encName 后条数校验不一致，保留加密箱');
            return;
          }
        } finally {
          await plain.close();
        }
      } finally {
        await enc.close();
      }

      await hive.deleteBoxFromDisk(encName);
    } catch (e, st) {
      // 单箱失败只跳过该箱：加密箱还在，下次启动重试。
      AppLog.e('enc-migration', '迁移 $name 失败，跳过该箱', error: e, stack: st);
    }
  }
}
