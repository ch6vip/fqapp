import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/player_layout_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlayerLayoutPreferences.mode.value = PlayerLayoutMode.immersive;
  });

  test('decode maps every storage name and falls back to immersive', () {
    for (final mode in PlayerLayoutMode.values) {
      expect(PlayerLayoutPreferences.decode(mode.storageName), mode);
    }
    expect(
      PlayerLayoutPreferences.decode(null),
      PlayerLayoutMode.immersive,
    );
    expect(PlayerLayoutPreferences.decode(''), PlayerLayoutMode.immersive);
    // 旧版本 / 手改过的未知值不能把启动卡在非法枚举上。
    expect(
      PlayerLayoutPreferences.decode('side_by_side'),
      PlayerLayoutMode.immersive,
    );
  });

  test('save writes the storage name without touching the notifier', () async {
    expect(await PlayerLayoutPreferences.save(PlayerLayoutMode.split), isTrue);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString(PlayerLayoutPreferences.key), 'split');
    // 内存态由调用方（设置页）自己维护，save 只负责落盘。
    expect(
      PlayerLayoutPreferences.mode.value,
      PlayerLayoutMode.immersive,
    );
  });

  test('the mode notifier only reports real changes', () {
    var notifications = 0;
    void listener() => notifications++;
    PlayerLayoutPreferences.mode.addListener(listener);
    addTearDown(
      () => PlayerLayoutPreferences.mode.removeListener(listener),
    );

    PlayerLayoutPreferences.mode.value = PlayerLayoutMode.auto;
    PlayerLayoutPreferences.mode.value = PlayerLayoutMode.auto;
    PlayerLayoutPreferences.mode.value = PlayerLayoutMode.split;

    expect(notifications, 2);
  });

  test('every mode carries complete labels and an ordered storage name', () {
    for (final mode in PlayerLayoutMode.values) {
      expect(mode.storageName, isNotEmpty);
      expect(mode.label, isNotEmpty);
      expect(mode.shortLabel, isNotEmpty);
      expect(mode.description, isNotEmpty);
    }
    expect(
      PlayerLayoutMode.values.map((mode) => mode.storageName).toList(),
      ['immersive', 'auto', 'split'],
    );
  });
}
