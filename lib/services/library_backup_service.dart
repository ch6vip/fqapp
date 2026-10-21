import 'platform_channel.dart';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../models/library_backup.dart';
import 'library_store.dart';
import 'shelf_store.dart';

class LibraryBackupService {
  static const _channel = AppMethodChannel('fqapp/library_backup');

  Future<LibraryBackup> capture() async {
    final library = LibraryStore.instance;
    final shelfStore = ShelfStore.instance;
    if (!library.isInitialized || !shelfStore.isReady) {
      throw StateError('本机数据尚未初始化');
    }
    final snapshot = await library.backupSnapshot();
    final shelf = shelfStore.records();
    return Isolate.run(
      () => LibraryBackup.capture(
        shelf: shelf,
        history: snapshot.history,
        watched: snapshot.watched,
      ),
    );
  }

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
    return (shelf: shelf, history: library.history, episodes: library.episodes);
  }
}
