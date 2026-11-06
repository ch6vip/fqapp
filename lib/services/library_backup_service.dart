import 'platform_channel.dart';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../models/library_backup.dart';
import 'library_store.dart';
import 'shelf_group_store.dart';
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
    // A broken or unopened group box must not block exporting shelf/history;
    // the page tells the user this backup carries no groups (D-M9).
    final groups = ShelfGroupStore.instance.isReady
        ? ShelfGroupStore.instance.backupOrganization()
        : const <String, dynamic>{};
    return Isolate.run(
      () => LibraryBackup.capture(
        shelf: shelf,
        history: snapshot.history,
        watched: snapshot.watched,
        groups: groups,
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

  Future<({int shelf, int history, int episodes, int groups, int assignments})>
  restore(LibraryBackup backup) async {
    if (!LibraryStore.instance.isInitialized || !ShelfStore.instance.isReady) {
      throw StateError('本机数据尚未初始化');
    }
    final groupStore = ShelfGroupStore.instance;
    // A backup that carries groups cannot be restored into a store that is
    // not ready; refuse before any write so a retry stays idempotent.
    if (backup.groups.isNotEmpty && !groupStore.isReady) {
      throw StateError('本地分类尚未初始化');
    }
    // Every record was validated by LibraryBackup before any write. Groups go
    // first (so assignment capacity is known), then shelf, then history; all
    // three merges only fill gaps, so retries are idempotent.
    final merge = backup.groups.isEmpty
        ? (groups: 0, assignments: 0)
        : await groupStore.mergeBackup(backup.groups);
    final shelf = await ShelfStore.instance.mergeBackup(backup.shelf);
    final library = await LibraryStore.instance.mergeBackup(
      history: backup.history,
      watched: backup.watched,
    );
    return (
      shelf: shelf,
      history: library.history,
      episodes: library.episodes,
      groups: merge.groups,
      assignments: merge.assignments,
    );
  }
}
