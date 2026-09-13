import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/library_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = LibraryStore.instance;
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-b03-test-');
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('an undated history entry survives the trim it triggers', () async {
    await store.init();
    final history = Hive.box('history');
    await history.putAll({
      for (var index = 0; index < 100; index++)
        'record-$index': {'id': 'record-$index', 'time': index},
    });

    await store.addHistory({
      'id': 'shelf-only',
      'kind': 'audio',
      'inShelf': true,
    });

    expect(history.containsKey('shelf-only'), isTrue);
    expect(
      store.historySnapshot().map((entry) => entry['id']),
      contains('shelf-only'),
    );
  });

  test('clearHistory is not overtaken by a pending addHistory', () async {
    await store.init();
    final history = Hive.box('history');
    await history.put('shared', {'kind': 'audio', 'position': 45, 'time': 100});

    final pending = store.addHistory({
      'id': 'shared',
      'kind': 'book',
      'position': 500,
      'time': 101,
    });
    final cleared = store.clearHistory();
    await Future.wait([pending, cleared]);

    expect(history.containsKey('shared'), isFalse);
    expect(store.historySnapshot(), isEmpty);
  });

  test('clearReadingData clears history and reading time together', () async {
    await store.init();
    await store.addHistory({'id': 'book-1', 'kind': 'book', 'time': 1});
    await store.accumulateReadTime(
      'book-1',
      'book',
      120,
      at: DateTime(2026, 9, 8),
    );
    expect(store.readTimeSnapshot(), isNotEmpty);

    await store.clearReadingData();

    expect(store.historySnapshot(), isEmpty);
    expect(store.readTimeSnapshot(), isEmpty);
    expect(Hive.box('history').isEmpty, isTrue);
    expect(Hive.box('read_time').isEmpty, isTrue);
  });
}
