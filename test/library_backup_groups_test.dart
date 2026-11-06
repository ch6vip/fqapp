import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/library_backup_service.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';

/// 备份中的书架分组：可选顶层 `groups`、只补缺恢复、旧文件兼容。
///
/// 契约来自设计 §3.6 与 decisions #8：版本号仍为 1；空分组不写字段；
/// 非法分组在任何恢复写入前拒绝；分组不可用不阻断导出。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final library = LibraryStore.instance;
  final shelf = ShelfStore.instance;
  final groups = ShelfGroupStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-backup-groups-');
    Hive.init(directory.path);
    await library.init();
    await shelf.init();
    groups.maxVisibleGroups = 100;
    groups.maxGroupRecords = ShelfGroupStore.hardMaxGroupRecords;
    groups.maxAssignments = ShelfGroupStore.hardMaxAssignments;
    groups.writeOrganization = null;
  });

  tearDown(() async {
    await groups.whenIdle();
    await Hive.close().timeout(
      const Duration(seconds: 10),
      onTimeout: () => const <void>[],
    );
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Temp directory cleanup is noise.
    }
  });

  test('groups round-trip and an empty organization is omitted', () {
    final organization = _organization(
      groups: {'g1-abc': _group('想读')},
      assignments: {'book:123': _assignment('g1-abc')},
    );
    final backup = LibraryBackup.capture(
      shelf: [ShelfRecord(item: _item('123'), addedAt: DateTime(2020))],
      history: [],
      watched: {},
      groups: organization,
    );
    expect(backup.groupsIncluded, isTrue);
    expect(backup.groupCount, 1);
    expect(backup.assignmentCount, 1);

    final restored = LibraryBackup.decode(backup.encode());
    expect(restored.groupsIncluded, isTrue);
    expect(restored.groups, organization);

    final empty = LibraryBackup.capture(shelf: [], history: [], watched: {});
    expect(empty.groupsIncluded, isFalse);
    expect(utf8.decode(empty.encode()), isNot(contains('"groups"')));
  });

  test('a backup without a groups field decodes as no groups', () {
    final bytes = LibraryBackup.capture(
      shelf: [],
      history: [],
      watched: {},
    ).encode();
    final restored = LibraryBackup.decode(bytes);
    expect(restored.groups, isEmpty);
    expect(restored.groupsIncluded, isFalse);
  });

  test('capture drops tombstones, local assignments and dangling groups', () {
    final organization = _organization(
      groups: {'g1-abc': _group('想读'), 'g2-def': _group('已删', deleted: true)},
      assignments: {
        'book:123': _assignment('g1-abc'),
        'book:456': _assignment('g2-def'),
        'book:789': _assignment('g9-missing'),
        'book:local_1_ab': _assignment('g1-abc'),
      },
    );
    final backup = LibraryBackup.capture(
      shelf: [
        ShelfRecord(item: _item('123'), addedAt: DateTime(2020)),
        ShelfRecord(item: _item('local_1_ab'), addedAt: DateTime(2020)),
      ],
      history: [],
      watched: {},
      groups: organization,
    );
    expect(backup.groupsIncluded, isTrue);
    expect(backup.groupCount, 1);
    expect(backup.assignmentCount, 1);
    expect((backup.groups['assignments'] as Map).keys, ['book:123']);
    expect(backup.excludedLocalRecords, 1);
    expect(backup.shelf, hasLength(1));
  });

  test('invalid group documents are rejected before any restore write', () {
    final cases = <String, Object?>{
      'version': {'version': 2, 'groups': {}, 'assignments': {}},
      'empty name': _organization(
        groups: {
          'g1-a': {'name': ' ', 'at': 1, 'deleted': false},
        },
      ),
      'negative at': _organization(
        groups: {
          'g1-a': {'name': '想读', 'at': -1, 'deleted': false},
        },
      ),
      'bad deleted': _organization(
        groups: {
          'g1-a': {'name': '想读', 'at': 1, 'deleted': 'yes'},
        },
      ),
      'bad assignment at': _organization(
        groups: {'g1-a': _group('想读')},
        assignments: {
          'book:1': {'group': 'g1-a', 'at': -1},
        },
      ),
      'bad assignment group': _organization(
        groups: {'g1-a': _group('想读')},
        assignments: {
          'book:1': {'group': 'not-a-group', 'at': 1},
        },
      ),
      'too many groups': _organization(
        groups: {
          for (var i = 0; i <= ShelfGroupStore.hardMaxGroupRecords; i++)
            'g1-$i': _group('组$i'),
        },
      ),
      'too many assignments': _organization(
        assignments: {
          for (var i = 0; i <= ShelfGroupStore.hardMaxAssignments; i++)
            'book:$i': _assignment(ShelfGroupStore.unfiled),
        },
      ),
    };
    for (final entry in cases.entries) {
      expect(
        () => LibraryBackup.decode(_bytesWithGroups(entry.value)),
        throwsFormatException,
        reason: entry.key,
      );
      expect(library.historySnapshot(), isEmpty, reason: entry.key);
      expect(shelf.records(), isEmpty, reason: entry.key);
    }
  });

  test(
    'restore merges groups first, reports counts and is idempotent',
    () async {
      await groups.init();
      final backup = LibraryBackup.capture(
        shelf: [ShelfRecord(item: _item('1'), addedAt: DateTime(2020))],
        history: [
          {'id': '1', 'kind': 'book'},
        ],
        watched: {},
        groups: _organization(
          groups: {'g1-a': _group('想读'), 'g2-b': _group('在读')},
          assignments: {
            'book:1': _assignment('g1-a'),
            'shuqi/book:2': _assignment('g2-b'),
          },
        ),
      );
      final service = LibraryBackupService();
      expect(await service.restore(backup), (
        shelf: 1,
        history: 1,
        episodes: 0,
        groups: 2,
        assignments: 2,
      ));
      expect(groups.groups.values, containsAll(['想读', '在读']));
      expect(groups.groupOfKey('book:1'), 'g1-a');
      expect(groups.groupOfKey('shuqi/book:2'), 'g2-b');

      expect(await service.restore(backup), (
        shelf: 0,
        history: 0,
        episodes: 0,
        groups: 0,
        assignments: 0,
      ));
      expect(groups.groups, hasLength(2));
    },
  );

  test('existing groups and assignments are never overwritten', () async {
    await groups.init();
    final local = await groups.addGroup('想读');
    await groups.assignKeys(['book:1'], local);
    final backup = LibraryBackup.capture(
      shelf: [],
      history: [],
      watched: {},
      groups: _organization(
        groups: {'g9-zz': _group('想读')},
        assignments: {
          'book:1': _assignment('g9-zz'),
          'book:2': _assignment('g9-zz'),
        },
      ),
    );
    final result = await LibraryBackupService().restore(backup);
    expect(result.groups, 0);
    expect(result.assignments, 1);
    expect(groups.groups, hasLength(1));
    expect(groups.groupOfKey('book:1'), local);
    expect(groups.groupOfKey('book:2'), local);
  });

  test(
    'a ready group store with no groups exports no groups field and restores',
    () async {
      await groups.init();
      expect(groups.isReady, isTrue);
      expect(groups.groups, isEmpty);
      await shelf.add(_item('1'));
      final backup = await LibraryBackupService().capture();
      // The store is ready but empty: the three-key organization must be
      // normalized away so the field is omitted and the page does not claim
      // "0 个分组" (D-B1).
      expect(backup.groupsIncluded, isFalse);
      expect(utf8.decode(backup.encode()), isNot(contains('"groups"')));

      // A backup without groups must restore even when the group store is not
      // ready (D-M9); the readiness gate only applies to grouped backups.
      await EncryptedHive.box<dynamic>(Hive, ShelfGroupStore.boxName).close();
      expect(groups.isReady, isFalse);
      expect(await LibraryBackupService().restore(backup), (
        shelf: 0,
        history: 0,
        episodes: 0,
        groups: 0,
        assignments: 0,
      ));
    },
  );

  test('malformed local ids are excluded instead of failing the export', () {
    final backup = LibraryBackup.capture(
      shelf: [
        ShelfRecord(item: _item('local_foo'), addedAt: DateTime(2020)),
        ShelfRecord(item: _item('local_123'), addedAt: DateTime(2020)),
        ShelfRecord(item: _item('local_1_XYZ'), addedAt: DateTime(2020)),
        ShelfRecord(
          item: _item('1', seriesId: 'local_foo'),
          addedAt: DateTime(2020),
        ),
        ShelfRecord(item: _item('123'), addedAt: DateTime(2020)),
      ],
      history: [],
      watched: {},
    );
    // The pre-migration rule excluded every `local_`-prefixed id; malformed
    // ids must not slip into the file and make `_id` reject the whole export.
    expect(backup.shelf, hasLength(1));
    expect(backup.shelf.single.item.id, '123');
    expect(backup.excludedLocalRecords, 4);
    expect(() => LibraryBackup.decode(backup.encode()), returnsNormally);
  });

  test(
    'export still carries shelf and history when the group store is not ready',
    () async {
      expect(groups.isReady, isFalse);
      await shelf.add(_item('1'));
      await library.addHistory({'id': '1', 'kind': 'book'});
      final backup = await LibraryBackupService().capture();
      expect(backup.groupsIncluded, isFalse);
      expect(backup.shelf, hasLength(1));
      expect(backup.history, hasLength(1));
    },
  );

  test(
    'restore refuses a grouped backup before writing when groups are not ready',
    () async {
      expect(groups.isReady, isFalse);
      final backup = LibraryBackup.capture(
        shelf: [ShelfRecord(item: _item('1'), addedAt: DateTime(2020))],
        history: [
          {'id': '1', 'kind': 'book'},
        ],
        watched: {},
        groups: _organization(
          groups: {'g1-a': _group('想读')},
          assignments: {'book:1': _assignment('g1-a')},
        ),
      );
      await expectLater(
        LibraryBackupService().restore(backup),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '本地分类尚未初始化',
          ),
        ),
      );
      expect(shelf.records(), isEmpty);
      expect(library.historySnapshot(), isEmpty);
    },
  );

  test('an old backup without groups restores shelf and history', () async {
    final backup = LibraryBackup.capture(
      shelf: [ShelfRecord(item: _item('1'), addedAt: DateTime(2020))],
      history: [
        {'id': '1', 'kind': 'book'},
      ],
      watched: {},
    );
    expect(await LibraryBackupService().restore(backup), (
      shelf: 1,
      history: 1,
      episodes: 0,
      groups: 0,
      assignments: 0,
    ));
  });
}

Map<String, dynamic> _organization({
  Map<String, dynamic>? groups,
  Map<String, dynamic>? assignments,
}) => {
  'version': 1,
  'groups': groups ?? const <String, dynamic>{},
  'assignments': assignments ?? const <String, dynamic>{},
};

Map<String, dynamic> _group(String name, {int at = 1, bool deleted = false}) =>
    {'name': name, 'at': at, 'deleted': deleted};

Map<String, dynamic> _assignment(String group, {int at = 1}) => {
  'group': group,
  'at': at,
};

Uint8List _bytesWithGroups(Object? groups) {
  final base =
      jsonDecode(
            utf8.decode(
              LibraryBackup.capture(
                shelf: [],
                history: [],
                watched: {},
              ).encode(),
            ),
          )
          as Map<String, dynamic>;
  base['groups'] = groups;
  return Uint8List.fromList(utf8.encode(jsonEncode(base)));
}

MediaItem _item(String id, {String? seriesId}) => MediaItem(
  id: id,
  title: '作品',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
  seriesId: seriesId,
);
