import 'platform_channel.dart';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../models/library_backup.dart';
import 'ai_reading/ai_backup.dart';
import 'ai_reading/ai_controller.dart';
import 'library_store.dart';
import 'shelf_store.dart';

class LibraryBackupService {
  static const _channel = AppMethodChannel('fqapp/library_backup');

  AiBackupRestoreResult? lastAiRestore;
  String? lastAiExportNote;

  Future<LibraryBackup> capture({
    bool includeAi = true,
    String? aiBookId,
    bool compactAi = false,
  }) async {
    final library = LibraryStore.instance;
    final shelfStore = ShelfStore.instance;
    if (!library.isInitialized || !shelfStore.isReady) {
      throw StateError('本机数据尚未初始化');
    }
    final snapshot = await library.backupSnapshot();
    final shelf = shelfStore.records();
    lastAiExportNote = null;
    String? aiData;
    if (includeAi) {
      try {
        aiData = await AiBackupService.instance.encode(
          bookId: aiBookId,
          includeTrialDetails: !compactAi,
        );
      } on FormatException {
        rethrow;
      } catch (error) {
        // The shelf/progress backup must still work when the encrypted AI box
        // is locked. This is reported in the export message, not hidden.
        aiData = null;
        lastAiExportNote = 'AI 数据暂不可用，本次备份未包含：$error';
      }
    }
    Future<LibraryBackup> build(String? data) => Isolate.run(
      () => LibraryBackup.capture(
        shelf: shelf,
        history: snapshot.history,
        watched: snapshot.watched,
        aiData: data,
      ),
    );

    var backup = await build(aiData);
    try {
      backup.encode();
      return backup;
    } on FormatException {
      if (!includeAi || aiData == null) rethrow;
      if (!compactAi) {
        // Optional trial rows are the first thing to drop. Required feedback,
        // protections and prompts are never removed silently.
        aiData = await AiBackupService.instance.encode(
          bookId: aiBookId,
          includeTrialDetails: false,
        );
        backup = await build(aiData);
        try {
          backup.encode();
          lastAiExportNote = '备份超过 16 MB，已省略试验明细；反馈、保护和提示词仍完整。';
          return backup;
        } on FormatException {
          // fall through to the explicit failure below
        }
      }
      throw const FormatException(
        'AI 数据仍超过 16 MB。请使用「按书导出 AI 资产」，或先清理部分历史后重试；'
        '不会生成缺少必需分段的备份。',
      );
    }
  }

  Future<Set<String>> aiBookIds() =>
      AiBackupService.instance.bookIdsWithAssets();

  Future<bool> export(LibraryBackup backup) async {
    final bytes = await Isolate.run(backup.encode);
    final stamp = backup.createdAt
        .toLocal()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    return await _channel.invokeMethod<bool>('saveBackup', {
          'name': 'fqapp-backup-$stamp.json',
          'bytes': bytes,
        }) ??
        false;
  }

  Future<LibraryBackup?> pick() async {
    final bytes = await _channel.invokeMethod<Uint8List>('openBackup');
    return bytes == null
        ? null
        : Isolate.run(() => LibraryBackup.decode(bytes));
  }

  Future<({int shelf, int history, int episodes})> restore(
    LibraryBackup backup,
  ) async {
    if (!LibraryStore.instance.isInitialized || !ShelfStore.instance.isReady) {
      throw StateError('本机数据尚未初始化');
    }
    // Every record was validated by LibraryBackup before any write. Boxes do
    // not share a transaction; retries only fill missing identities/episodes.
    final library = await LibraryStore.instance.mergeBackup(
      history: backup.history,
      watched: backup.watched,
    );
    final shelf = await ShelfStore.instance.mergeBackup(backup.shelf);
    // AI assets are restored after the shelf merge. The AI importer does a
    // full preflight before writes and keeps local-book assets pending.
    lastAiRestore = await restoreAi(backup);
    return (shelf: shelf, history: library.history, episodes: library.episodes);
  }

  Future<AiBackupRestoreResult?> restoreAi(LibraryBackup backup) async {
    final ai = backup.aiData;
    if (ai == null || ai.isEmpty) return null;
    await AiReadingController.instance.init();
    return AiBackupService.instance.decodeAndRestore(ai);
  }
}
