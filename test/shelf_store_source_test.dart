import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/encrypted_hive.dart';
import 'package:fqapp/services/shelf_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final shelf = ShelfStore.instance;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fqapp-shelf-source-');
    Hive.init(directory.path);
    await shelf.init();
  });

  tearDown(() async {
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

  group('storage keys', () {
    test('fanqie keys are unchanged and other sources are qualified', () {
      expect(ShelfStore.keyFor('book', '123'), 'shelf_v1:book:123');
      expect(
        ShelfStore.keyFor('book', '123', source: 'shuqi'),
        'shelf_v1:shuqi/book:123',
      );
      expect(
        ShelfStore.contentKeyOf(_item('123', source: 'shuqi')),
        'shuqi/book:123',
      );
      expect(
        ShelfStore.keyOf(_item('123', source: 'shuqi')),
        'shelf_v1:shuqi/book:123',
      );
      // The series id wins for episode items.
      expect(
        ShelfStore.keyOf(_item('episode-1', kind: 'video', seriesId: '9')),
        'shelf_v1:video:9',
      );
    });
  });

  group('record round-trip', () {
    test('source, intro, categories, status and word count persist', () async {
      await shelf.add(
        _item(
          '123',
          source: 'shuqi',
          intro: '简介',
          categories: const ['玄幻', '都市'],
          creationStatus: 0,
          wordNumber: 123456,
        ),
      );
      final record = shelf.records().single;
      expect(record.item.source, 'shuqi');
      expect(record.item.intro, '简介');
      expect(record.item.categories, ['玄幻', '都市']);
      expect(record.item.creationStatus, 0);
      expect(record.item.wordNumber, 123456);
    });

    test('fanqie records keep the old shape and survive a reopen', () async {
      await shelf.add(_item('123', title: '番茄书'));
      final box = EncryptedHive.box<dynamic>(Hive, ShelfStore.boxName);
      final raw = box.get('shelf_v1:book:123') as Map;
      expect(raw.containsKey('source'), isFalse);
      expect(raw.containsKey('intro'), isFalse);
      expect(raw.containsKey('categories'), isFalse);

      await Hive.close();
      await shelf.init();
      expect(shelf.records().single.item.source, 'fanqie');
    });

    test('the same numeric id can exist for two sources', () async {
      await shelf.add(_item('123', title: '番茄书'));
      await shelf.add(_item('123', title: '书旗书', source: 'shuqi'));

      expect(shelf.records(), hasLength(2));
      expect(shelf.contains('book', '123'), isTrue);
      expect(shelf.contains('book', '123', source: 'shuqi'), isTrue);
      expect(shelf.contains('book', '123', source: 'other'), isFalse);
      expect(shelf.records().map((record) => record.item.source).toSet(), {
        'fanqie',
        'shuqi',
      });
    });
  });

  group('legacy records', () {
    test('a record without source reads as a fanqie book', () async {
      await _putRaw('shelf_v1:book:777', {
        'id': '777',
        'kind': 'book',
        'title': '旧番茄记录',
        'addedAt': 1,
      });
      final record = shelf.records().single;
      expect(record.item.source, 'fanqie');
    });

    test(
      'a source-qualified key heals a record that never wrote source',
      () async {
        await _putRaw('shelf_v1:shuqi/book:888', {
          'id': '888',
          'kind': 'book',
          'title': '旧书旗记录',
          'addedAt': 2,
        });
        final record = shelf.records().single;
        expect(record.item.source, 'shuqi');
        expect(record.item.title, '旧书旗记录');
      },
    );

    test('an invalid source field falls back to the storage key', () async {
      await _putRaw('shelf_v1:shuqi/book:999', {
        'id': '999',
        'kind': 'book',
        'title': '书旗记录',
        'source': 'BAD SOURCE',
        'addedAt': 3,
      });
      expect(shelf.records().single.item.source, 'shuqi');
    });

    test('missing optional fields fall back to defaults', () async {
      await _putRaw('shelf_v1:book:1000', {
        'id': '1000',
        'kind': 'book',
        'title': '无扩展字段',
        'addedAt': 4,
      });
      final item = shelf.records().single.item;
      expect(item.intro, '');
      expect(item.categories, isEmpty);
      expect(item.creationStatus, -1);
      expect(item.wordNumber, 0);
    });
  });
}

Future<void> _putRaw(String key, Map<String, Object> raw) async {
  final box = EncryptedHive.box<dynamic>(Hive, ShelfStore.boxName);
  await box.put(key, raw);
}

MediaItem _item(
  String id, {
  String title = 'T',
  String kind = 'book',
  String? seriesId,
  String source = 'fanqie',
  String intro = '',
  List<String> categories = const [],
  int creationStatus = -1,
  int wordNumber = 0,
}) => MediaItem(
  id: id,
  title: title,
  cover: '',
  author: '作者',
  badge: '',
  ep: '',
  kind: kind,
  seriesId: seriesId,
  source: source,
  intro: intro,
  categories: categories,
  creationStatus: creationStatus,
  wordNumber: wordNumber,
);
