import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/library_backup_service.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/media_history_store.dart';
import 'package:fqapp/services/shelf_group_store.dart';
import 'package:fqapp/services/shelf_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final library = LibraryStore.instance;
  final shelf = ShelfStore.instance;
  final groups = ShelfGroupStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-backup-test-');
    Hive.init(directory.path);
    await library.init();
    await shelf.init();
    await groups.init();
  });

  tearDown(() async {
    await groups.whenIdle();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'portable backup retains progress units and excludes local data',
    () async {
      await library.addHistory({
        'id': '123',
        'kind': 'book',
        'chapterId': 'chapter-1',
        'positionVersion': 2,
        'textOffset': 431,
        'position': 120.0,
        'cover': '/private/cover.jpg',
        'unexpectedSecret': 'never-export',
      });
      await scopedHistoryStore(library, 'audio').addHistory({
        'id': '123',
        'chapterId': 'audio-1',
        'position': 38.5,
        'toneId': 'voice-1',
        'rate': 1.5,
      });
      await scopedHistoryStore(library, 'manga').addHistory({
        'id': '123',
        'chapterId': 'comic-1',
        'position': 4.25,
        'positionUnit': 'comic-page',
      });
      await library.addHistory({'id': 'local_100_abcd', 'kind': 'book'});
      await shelf.add(_item('local_100_abcd'));
      final service = LibraryBackupService();
      final bytes = (await service.capture()).encode();
      final restored = LibraryBackup.decode(bytes);
      expect(restored.excludedLocalRecords, 2);
      expect(restored.shelf, isEmpty);
      expect(restored.history, hasLength(3));
      expect(utf8.decode(bytes), isNot(contains('never-export')));
      expect(utf8.decode(bytes), isNot(contains('/private/')));
      final novel = restored.history.singleWhere((e) => e['kind'] == 'book');
      expect(novel['textOffset'], 431);
      expect(novel['positionVersion'], 2);
      final manga = restored.history.singleWhere((e) => e['kind'] == 'manga');
      expect(manga['positionUnit'], 'comic-page');

      await library.clearHistory();
      await service.restore(restored);
      expect((await library.historyEntry('123'))?['textOffset'], 431);
      expect(
        (await scopedHistoryStore(
          library,
          'audio',
        ).historyEntry('123'))?['position'],
        38.5,
      );
      expect(
        (await scopedHistoryStore(
          library,
          'manga',
        ).historyEntry('123'))?['position'],
        4.25,
      );
    },
  );

  test(
    'merge keeps current records, unions legacy watched data, and can retry',
    () async {
      await library.addHistory({'id': 'same', 'kind': 'book', 'episode': 9});
      await shelf.add(_item('same', title: '本机标题'));
      final localAddedAt = shelf.records().single.addedAt;
      await Hive.box('watched_episodes').put('series-1', ['ep-1']);
      final backup = LibraryBackup.capture(
        shelf: [
          ShelfRecord(
            item: _item('same', title: '旧标题'),
            addedAt: DateTime(2020),
          ),
          ShelfRecord(item: _item('new'), addedAt: DateTime(2020)),
        ],
        history: [
          {'id': 'same', 'kind': 'book', 'episode': 1},
          for (var i = 0; i < 110; i++) {'id': 'new-$i', 'kind': 'book'},
        ],
        watched: {
          'series-1': {'ep-1': 100, 'ep-2': 200},
        },
      );
      final service = LibraryBackupService();
      expect(await service.restore(backup), (
        shelf: 1,
        history: 110,
        episodes: 1,
        groups: 0,
        assignments: 0,
      ));
      expect(library.historySnapshot(), hasLength(111));
      expect((await library.historyEntry('same'))?['episode'], 9);
      expect(await library.watchedEpisodeIds('series-1'), {'ep-1', 'ep-2'});
      final current = shelf.records().singleWhere((e) => e.item.id == 'same');
      expect(current.item.title, '本机标题');
      expect(current.addedAt, localAddedAt);
      expect(await service.restore(backup), (
        shelf: 0,
        history: 0,
        episodes: 0,
        groups: 0,
        assignments: 0,
      ));
      expect(library.historySnapshot(), hasLength(111));
    },
  );

  test('source and card metadata survive a round-trip', () async {
    final backup = LibraryBackup.capture(
      shelf: [
        ShelfRecord(
          item: _item('123', title: '番茄书'),
          addedAt: DateTime(2020),
        ),
        ShelfRecord(
          item: _item(
            '123',
            title: '书旗书',
            source: 'shuqi',
            intro: '简介',
            categories: const ['玄幻', '热血'],
            creationStatus: 0,
            wordNumber: 123456,
          ),
          addedAt: DateTime(2021),
        ),
      ],
      history: [],
      watched: {},
    );
    final restored = LibraryBackup.decode(backup.encode());
    expect(restored.shelf, hasLength(2));
    final fanqie = restored.shelf.singleWhere((e) => e.item.source == 'fanqie');
    final shuqi = restored.shelf.singleWhere((e) => e.item.source == 'shuqi');
    expect(fanqie.item.title, '番茄书');
    expect(shuqi.item.title, '书旗书');
    expect(shuqi.item.intro, '简介');
    expect(shuqi.item.categories, ['玄幻', '热血']);
    expect(shuqi.item.creationStatus, 0);
    expect(shuqi.item.wordNumber, 123456);
    // Same numeric id, distinct source-qualified identities.
    expect(ShelfStore.keyOf(fanqie.item), 'shelf_v1:book:123');
    expect(ShelfStore.keyOf(shuqi.item), 'shelf_v1:shuqi/book:123');

    await LibraryBackupService().restore(restored);
    expect(shelf.records(), hasLength(2));
    expect(shelf.contains('book', '123'), isTrue);
    expect(shelf.contains('book', '123', source: 'shuqi'), isTrue);
  });

  test(
    'file validation rejects malformed final records before any writes',
    () async {
      final json =
          jsonDecode(
                LibraryBackup.capture(
                  shelf: [],
                  history: [
                    {'id': 'valid', 'kind': 'book'},
                  ],
                  watched: {},
                ).encodeAsText(),
              )
              as Map<String, dynamic>;
      (json['history'] as List).add({
        'id': 'bad',
        'kind': 'book',
        'position': -1,
      });
      expect(
        () => LibraryBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        throwsFormatException,
      );
      expect(library.historySnapshot(), isEmpty);
      json['history'] = [
        {'id': 'local_100_abcd', 'kind': 'book'},
      ];
      expect(
        () => LibraryBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        throwsFormatException,
      );
      json['version'] = 999;
      expect(
        () => LibraryBackup.decode(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        throwsFormatException,
      );
    },
  );
}

MediaItem _item(
  String id, {
  String title = '作品',
  String source = 'fanqie',
  String intro = '',
  List<String> categories = const [],
  int creationStatus = -1,
  int wordNumber = 0,
}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
  source: source,
  intro: intro,
  categories: categories,
  creationStatus: creationStatus,
  wordNumber: wordNumber,
);

extension on LibraryBackup {
  String encodeAsText() => utf8.decode(encode());
}
