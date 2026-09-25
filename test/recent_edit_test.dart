import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/media_history_store.dart';

/// F08：最近页的编辑/选择/删除。
///
/// 官方依据（`LatestShortVideoFragmentImpl`）：
/// - `Me()` 进编辑、`Le()` 完成、`Ke()` 全选/取消全选（`bf()` 把文案换成
///   `wp`「取消全选」/`a5`「全选」）
/// - `ue()` 删除前先弹确认框（`Te()`：标题 `bb6`「确定删除浏览历史吗？」、
///   确认 `bil`「确认」、取消 `biu`「取消」，`setCancelable(false)`）
/// - 成功后 Toast「删除成功」（`:848`），失败「删除失败」（`:204`）
void main() {
  group('LibraryStore 精确删除', () {
    test('removes only the selected record', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LibraryStore.instance;
      final dir = await _tempDir('fqapp-recent-delete');
      Hive.init(dir.path);
      await store.init();
      await store.clearHistory();
      await store.addHistory({'id': 'a', 'kind': 'video', 'title': 'A'});
      await store.addHistory({'id': 'b', 'kind': 'manju', 'title': 'B'});
      await store.addHistory({'id': 'c', 'kind': 'video', 'title': 'C'});
      final removed = await store.removeHistoryEntries([
        (contentId: 'a', kind: 'video'),
      ]);
      expect(removed, greaterThan(0));
      expect(store.historyEntry('a'), completion(isNull));
      // 未选中的记录必须原样保留。
      expect((await store.historyEntry('b'))?['title'], 'B');
      expect((await store.historyEntry('c'))?['title'], 'C');
    });

    test('kind is part of the identity', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LibraryStore.instance;
      final dir = await _tempDir('fqapp-recent-delete-kind');
      Hive.init(dir.path);
      await store.init();
      await store.clearHistory();
      // 真实路径是作用域 store（同一条作品可能有 video/manju 两个作用域）。
      await scopedHistoryStore(store, 'video').addHistory({
        'id': 'x',
        'kind': 'video',
        'title': 'V',
      });
      await scopedHistoryStore(store, 'manju').addHistory({
        'id': 'x',
        'kind': 'manju',
        'title': 'M',
      });
      await store.removeHistoryEntries([(contentId: 'x', kind: 'manju')]);
      final remaining = store.historySnapshot();
      expect(remaining.length, 1);
      expect(remaining.first['title'], 'V');
    });

    test('a missing record reports zero removals', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LibraryStore.instance;
      final dir = await _tempDir('fqapp-recent-delete-missing');
      Hive.init(dir.path);
      await store.init();
      await store.clearHistory();
      expect(await store.removeHistoryEntry('nope', 'video'), isFalse);
    });
  });
}

Future<Directory> _tempDir(String prefix) async {
  final root = Directory.systemTemp;
  return root.createTemp(prefix);
}
