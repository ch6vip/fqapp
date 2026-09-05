import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/search_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'concurrent searches retain their order and remove duplicates',
    () async {
      final store = SearchHistoryStore.instance;
      await Future.wait([
        store.add('  Alpha  book '),
        store.add('Beta'),
        store.add('ALPHA book'),
      ]);
      expect(await store.load(), ['ALPHA book', 'Beta']);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getStringList('search_history_v1'), [
        'ALPHA book',
        'Beta',
      ]);
      await Future.wait([
        store.add('Gamma'),
        store.remove('beta'),
        store.clear(),
      ]);
      expect(await store.load(), isEmpty);
    },
  );

  test(
    'keeps twenty recent searches and tolerates malformed saved data',
    () async {
      SharedPreferences.setMockInitialValues({'search_history_v1': 42});
      final store = SearchHistoryStore.instance;
      expect(await store.load(), isEmpty);
      for (var i = 0; i < 24; i++) {
        await store.add('搜索$i');
      }
      final items = await store.load();
      expect(items, hasLength(20));
      expect(items.first, '搜索23');
      expect(items.last, '搜索4');
      await store.remove(' 搜索23 ');
      expect((await store.load()).first, '搜索22');
    },
  );
}
