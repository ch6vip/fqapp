import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/shelf_categories.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/shelf_group_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final store = ShelfGroupStore.instance;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fqapp-group-test-');
    Hive.init(directory.path);
    store.maxVisibleGroups = 100;
    store.maxGroupRecords = ShelfGroupStore.hardMaxGroupRecords;
    store.maxAssignments = ShelfGroupStore.hardMaxAssignments;
    store.writeOrganization = null;
    await store.init();
  });

  tearDown(() async {
    await store.whenIdle();
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

  group('groups', () {
    test(
      'add, rename and remove keep insertion order and tombstones',
      () async {
        final first = await store.addGroup(' 想读 ');
        final second = await store.addGroup('在读');
        expect(store.groups.keys.toList(), [first, second]);
        expect(store.groups[first], '想读');
        expect(store.nameOf(first), '想读');
        expect(store.nameOf(ShelfCategory.all), '全部书籍');
        expect(store.nameOf(ShelfCategory.unfiled), '未分类');

        await store.renameGroup(first, '待读');
        expect(store.groups[first], '待读');

        await store.removeGroup(first);
        expect(store.groups.keys.toList(), [second]);
        expect(store.nameOf(first), '全部书籍');
        final exported =
            (store.exportOrganization()['groups']
                    as Map<String, dynamic>)[first]
                as Map<String, dynamic>;
        expect(exported['deleted'], isTrue);
      },
    );

    test('rejects empty, duplicated and over-long names', () async {
      final id = await store.addGroup('想读');
      await expectLater(store.addGroup('想读'), throwsFormatException);
      await expectLater(store.addGroup('   '), throwsFormatException);
      await expectLater(store.addGroup('x' * 31), throwsFormatException);
      await expectLater(store.renameGroup(id, 'x' * 31), throwsFormatException);
      await store.addGroup('在读');
      await expectLater(store.renameGroup(id, '在读'), throwsFormatException);
      await expectLater(
        store.renameGroup('missing-group', '新名'),
        throwsFormatException,
      );
    });

    test(
      'visible and record limits are enforced with instance values',
      () async {
        store.maxVisibleGroups = 1;
        await store.addGroup('第一组');
        await expectLater(store.addGroup('第二组'), throwsFormatException);
        expect(store.groups, hasLength(1));

        store.maxVisibleGroups = 100;
        final id = await store.addGroup('第二组');
        await store.removeGroup(id);
        store.maxGroupRecords = 1;
        // The tombstone counts toward the record limit.
        await expectLater(store.addGroup('第三组'), throwsFormatException);
      },
    );

    test('every mutation notifies exactly once', () async {
      var notifications = 0;
      void listener() => notifications++;
      store.listenable.addListener(listener);
      addTearDown(() => store.listenable.removeListener(listener));

      final id = await store.addGroup('想读');
      expect(notifications, 1);
      await store.assignMany([_item('a'), _item('b')], id);
      expect(notifications, 2);
      await store.removeGroup(id);
      expect(notifications, 3);
    });
  });

  group('assignments', () {
    test('a batch writes once, dedupes series ids and can unfile', () async {
      final id = await store.addGroup('剧集');
      var notifications = 0;
      void listener() => notifications++;
      store.listenable.addListener(listener);
      addTearDown(() => store.listenable.removeListener(listener));

      await store.assignMany([
        _item('episode-1', kind: 'video', seriesId: '9'),
        _item('episode-2', kind: 'video', seriesId: '9'),
      ], id);
      expect(notifications, 1);
      expect(store.groupOfKey('video:9'), id);
      expect(
        (store.exportOrganization()['assignments'] as Map<String, dynamic>),
        hasLength(1),
      );

      await store.unassignMany([
        _item('episode-1', kind: 'video', seriesId: '9'),
      ]);
      expect(store.groupOfKey('video:9'), ShelfGroupStore.unfiled);
    });

    test('the same numeric id from two sources cannot collide', () async {
      final id = await store.addGroup('G');
      await store.assignKeys(['book:123'], id);
      expect(store.groupOfKey('book:123'), id);
      expect(store.groupOfKey('shuqi/book:123'), ShelfGroupStore.unfiled);

      await store.assignMany([_item('123', source: 'shuqi')], id);
      expect(store.groupOfKey('shuqi/book:123'), id);
      expect(store.groupOfKey('book:123'), id);

      await store.removeAssignments(['book:123']);
      expect(store.groupOfKey('book:123'), ShelfGroupStore.unfiled);
      expect(store.groupOfKey('shuqi/book:123'), id);
    });

    test(
      'invalid keys, unknown groups and over-limit batches are rejected',
      () async {
        final id = await store.addGroup('G');
        await expectLater(
          store.assignKeys(['not-a-key'], id),
          throwsFormatException,
        );
        await expectLater(
          store.assignMany([_item('a')], 'g1a2-missing'),
          throwsFormatException,
        );

        store.maxAssignments = 1;
        await expectLater(
          store.assignMany([_item('a'), _item('b')], id),
          throwsFormatException,
        );
        expect(
          store.exportOrganization()['assignments'] as Map<String, dynamic>,
          isEmpty,
        );
      },
    );

    test('author categories match without touching the group map', () async {
      expect(
        store.matchesKey('book:1', '张 三', shelfAuthorCategory('张 三')),
        isTrue,
      );
      expect(
        store.matchesKey('book:1', '张三', shelfAuthorCategory('张 三')),
        isFalse,
        reason: 'a single internal space is significant, as upstream',
      );
      expect(
        store.matchesKey('book:1', '李四', shelfAuthorCategory('张 三')),
        isFalse,
      );
      expect(
        store.matchesKey('book:1', '', shelfAuthorCategory('本地书籍')),
        isTrue,
      );
      expect(store.matchesKey('book:1', '', ShelfCategory.unfiled), isTrue);
      expect(store.matchesKey('book:1', '', ShelfCategory.all), isTrue);
    });
  });

  group('mergeBackup', () {
    test(
      'fills gaps only, remaps same names, skips tombstones and local keys',
      () async {
        final local = await store.addGroup('G');
        await store.assignMany([_item('1')], local);

        final incoming = {
          'version': 1,
          'groups': {
            'g1a-x': {'name': '想读', 'at': 100, 'deleted': false},
            'g1b-y': {'name': 'G', 'at': 101, 'deleted': false},
            'g1c-z': {'name': '删了', 'at': 102, 'deleted': true},
          },
          'assignments': {
            'book:1': {'group': 'g1a-x', 'at': 103},
            'book:2': {'group': 'g1a-x', 'at': 104},
            'book:3': {'group': 'g1b-y', 'at': 105},
            'book:local_1_ab': {'group': 'g1a-x', 'at': 106},
            'book:4': {'group': 'g1c-z', 'at': 107},
            'book:5': {'group': 'g9z-missing', 'at': 108},
            'book:6': {'group': '_unfiled', 'at': 109},
          },
        };

        final merged = await store.mergeBackup(incoming);
        expect(merged.groups, 1);
        expect(merged.assignments, 3);

        // Existing assignment wins; no overwrite.
        expect(store.groupOfKey('book:1'), local);
        // Same-name group remapped onto the local id.
        expect(store.groupOfKey('book:3'), local);
        expect(store.groupOfKey('book:2'), isNot(ShelfGroupStore.unfiled));
        expect(store.groupOfKey('book:2'), isNot(local));
        expect(store.groupOfKey('book:6'), ShelfGroupStore.unfiled);
        expect(store.groupOfKey('book:4'), ShelfGroupStore.unfiled);
        expect(store.groupOfKey('book:5'), ShelfGroupStore.unfiled);
        expect(store.groupOfKey('book:local_1_ab'), ShelfGroupStore.unfiled);
        expect(store.groups.values, isNot(contains('删了')));
        expect(store.groups.values, contains('想读'));

        // Idempotent: a retry changes nothing.
        final again = await store.mergeBackup(incoming);
        expect(again.groups, 0);
        expect(again.assignments, 0);
      },
    );

    test('invalid input throws before any write', () {
      final before = store.exportOrganization();
      expect(
        () => store.mergeBackup({
          'version': 2,
          'groups': <String, dynamic>{},
          'assignments': <String, dynamic>{},
        }),
        throwsFormatException,
      );
      expect(store.exportOrganization(), before);
    });

    test('a malformed group id is rejected before any write', () {
      final before = store.exportOrganization();
      expect(
        () => store.mergeBackup({
          'version': 1,
          'groups': {
            'foo': {'name': 'x', 'at': 1},
          },
          'assignments': <String, dynamic>{},
        }),
        throwsFormatException,
      );
      expect(store.exportOrganization(), before);
      expect(store.groups, isEmpty);
    });

    test('a merge that exceeds a limit writes nothing', () async {
      store.maxVisibleGroups = 1;
      await store.addGroup('G');
      final before = store.exportOrganization();
      final incoming = {
        'version': 1,
        'groups': {
          'g1a-x': {'name': '另一个', 'at': 100, 'deleted': false},
        },
        'assignments': <String, dynamic>{},
      };
      await expectLater(store.mergeBackup(incoming), throwsFormatException);
      expect(store.exportOrganization(), before);
      expect(store.groups, hasLength(1));
    });

    test('portableOrganization strips local book keys and tombstones', () {
      final portable = ShelfGroupStore.portableOrganization({
        'version': 1,
        'groups': {
          'g1a-x': {'name': '想读', 'at': 1, 'deleted': false},
          'g1b-y': {'name': '删了', 'at': 2, 'deleted': true},
        },
        'assignments': {
          'book:1': {'group': 'g1a-x', 'at': 3},
          'book:local_1_ab': {'group': 'g1a-x', 'at': 4},
          'book:2': {'group': 'g1b-y', 'at': 5},
          'book:3': {'group': '_unfiled', 'at': 6},
        },
      });
      expect(portable['groups'], hasLength(1));
      expect(portable['assignments'], hasLength(2));
      expect((portable['assignments'] as Map<String, dynamic>).keys, {
        'book:1',
        'book:3',
      });
    });
  });

  group('validateOrganization', () {
    test('rejects malformed documents', () {
      for (final input in <Object?>[
        null,
        'text',
        {'version': 1, 'groups': []},
        {
          'version': 1,
          'groups': {
            '_bad': {'name': 'x', 'at': 1},
          },
          'assignments': <String, dynamic>{},
        },
        {
          'version': 1,
          'groups': {
            'g1a-x': {'name': '', 'at': 1},
          },
          'assignments': <String, dynamic>{},
        },
        {
          'version': 1,
          'groups': {
            'g1a-x': {'name': 'x', 'at': -1},
          },
          'assignments': <String, dynamic>{},
        },
        // A group id must be a generated `g<base36>-<base36>` id; otherwise
        // the UI could list a category that `setCategoryOf` always rejects.
        {
          'version': 1,
          'groups': {
            'foo': {'name': 'x', 'at': 1},
          },
          'assignments': <String, dynamic>{},
        },
        {
          'version': 1,
          'groups': {
            'book:1': {'name': 'x', 'at': 1},
          },
          'assignments': <String, dynamic>{},
        },
        {
          'version': 1,
          'groups': <String, dynamic>{},
          'assignments': {
            'not-a-key': {'group': 'g1a-x', 'at': 1},
          },
        },
        {
          'version': 1,
          'groups': <String, dynamic>{},
          'assignments': {
            'book:1': {'group': 1, 'at': 1},
          },
        },
        {
          'version': 1,
          'groups': <String, dynamic>{},
          'assignments': {
            'book:1': {'group': '_all', 'at': 1},
          },
        },
        {
          'version': 1,
          'groups': <String, dynamic>{},
          'assignments': {
            'book:1': {'group': 'foo', 'at': 1},
          },
        },
      ]) {
        expect(
          () => ShelfGroupStore.validateOrganization(input),
          throwsFormatException,
          reason: '$input',
        );
      }
    });

    test('normalizes names and tombstones', () {
      final valid = ShelfGroupStore.validateOrganization({
        'version': 1,
        'groups': {
          'g1a-x': {'name': ' 想读 ', 'at': 1},
        },
        'assignments': {
          'shuqi/book:1': {'group': 'g1a-x', 'at': 2},
        },
      });
      final groups = valid['groups'] as Map<String, dynamic>;
      expect(groups['g1a-x'], {'name': '想读', 'at': 1, 'deleted': false});
      expect((valid['assignments'] as Map<String, dynamic>)['shuqi/book:1'], {
        'group': 'g1a-x',
        'at': 2,
      });
    });
  });

  group('lifecycle', () {
    test(
      'closing the box degrades reads and rejects writes until reopen',
      () async {
        final id = await store.addGroup('想读');
        await Hive.close();
        expect(store.isReady, isFalse);
        expect(store.groups, isEmpty);
        expect(store.groupOfKey('book:1'), ShelfGroupStore.unfiled);
        expect(store.resolveCategory(id), isNull);
        expect(store.matchesKey('book:1', '', ShelfCategory.all), isTrue);
        await expectLater(store.addGroup('另一个'), throwsStateError);

        await store.init();
        expect(store.isReady, isTrue);
        expect(store.groups[id], '想读');
        expect(store.resolveCategory(id), id);
      },
    );

    test('reload reopens its own box and keeps the durable state', () async {
      final id = await store.addGroup('想读');
      await store.reload();
      expect(store.groups[id], '想读');
    });

    test('a corrupt document is quarantined and treated as empty', () async {
      await Hive.close();
      final box = await EncryptedHive.openBox<dynamic>(
        Hive,
        ShelfGroupStore.boxName,
      );
      await box.put(ShelfGroupStore.documentKey, '{not json');
      await box.close();

      await store.init();
      expect(store.groups, isEmpty);

      final reopened = EncryptedHive.box<dynamic>(
        Hive,
        ShelfGroupStore.boxName,
      );
      final quarantined = reopened.keys.where(
        (key) => key.toString().startsWith(
          '${ShelfGroupStore.documentKey}.corrupt-',
        ),
      );
      expect(quarantined, hasLength(1));
    });

    test(
      'a write queued before a reload is not resurrected afterwards',
      () async {
        // `reload` waits for the queue, so the write is durable before the box
        // is reopened; the reopened store must read it back exactly once.
        final pending = store.addGroup('想读');
        await store.reload();
        await pending;
        expect(store.groups.values.where((name) => name == '想读'), hasLength(1));
      },
    );

    test(
      'a failed write restores the in-memory snapshot and the queue recovers',
      () async {
        final id = await store.addGroup('想读');
        final before = store.exportOrganization();
        var notifications = 0;
        void listener() => notifications++;
        store.listenable.addListener(listener);
        addTearDown(() => store.listenable.removeListener(listener));

        store.writeOrganization = (box, encoded) async {
          throw StateError('disk full');
        };
        addTearDown(() => store.writeOrganization = null);

        await expectLater(store.addGroup('在读'), throwsStateError);
        // Memory and the durable document both stay at the pre-write state.
        expect(store.exportOrganization(), before);
        expect(store.groups, {id: '想读'});
        expect(store.groups.values, isNot(contains('在读')));
        expect(notifications, 0, reason: 'a failed write must not notify');
        final box = EncryptedHive.box<dynamic>(Hive, ShelfGroupStore.boxName);
        final stored =
            jsonDecode(box.get(ShelfGroupStore.documentKey) as String)
                as Map<String, dynamic>;
        expect(stored, before);

        // The failed write does not poison the serialized queue.
        store.writeOrganization = null;
        final second = await store.addGroup('在读');
        expect(store.groups[second], '在读');
        expect(store.groups[id], '想读');
      },
    );
  });
}

MediaItem _item(
  String id, {
  String kind = 'book',
  String? seriesId,
  String source = 'fanqie',
  String author = '作者',
}) => MediaItem(
  id: id,
  title: 'T-$id',
  cover: '',
  author: author,
  badge: '',
  ep: '',
  kind: kind,
  seriesId: seriesId,
  source: source,
);
