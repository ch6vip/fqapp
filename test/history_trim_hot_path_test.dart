import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/library_store.dart';

/// Regression cover for the add-history hot path: imported history is exempt
/// from the 50-entry trim, so a large import must not make every local write
/// rebuild and sort the whole history snapshot.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = LibraryStore.instance;
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-history-trim-');
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'imported history does not force a snapshot rebuild on every write',
    () async {
      await store.init();
      final history = Hive.box('history');
      await history.putAll({
        for (var index = 0; index < 200; index++)
          'imported-$index': {
            'id': 'imported-$index',
            'time': index,
            'fanqieImported': true,
          },
      });
      final buildsBefore = store.historySnapshotBuilds;
      await store.addHistory({'id': 'local', 'title': '本地', 'time': 300});
      expect(store.historySnapshotBuilds, buildsBefore);
      expect(history.containsKey('imported-0'), isTrue);
      expect(await store.historyEntry('local'), isNotNull);
      expect(history.length, 201);
    },
  );

  test('local history still trims to 50 despite imported records', () async {
    await store.init();
    final history = Hive.box('history');
    await history.putAll({
      for (var index = 0; index < 200; index++)
        'imported-$index': {
          'id': 'imported-$index',
          'time': -index,
          'fanqieImported': true,
        },
      for (var index = 0; index < 100; index++)
        'local-$index': {'id': 'local-$index', 'time': index},
    });
    await store.addHistory({'id': 'local-new', 'title': '最新', 'time': 1000});
    // 49 retained local records plus the new one; every import survives.
    expect(history.length, 250);
    expect(history.containsKey('imported-0'), isTrue);
    expect(await store.historyEntry('local-new'), isNotNull);
    expect(
      store.historySnapshot().where((entry) {
        return entry['fanqieImported'] != true;
      }),
      hasLength(50),
    );
  });
}
