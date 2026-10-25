import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_channel_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DramaChannelPreferences.reset();
  });

  test('没有记录时落在推荐（当前与上一次都空）', () async {
    final preferences = await SharedPreferences.getInstance();
    DramaChannelPreferences.load(preferences);

    expect(DramaChannelPreferences.selectedType, isNull);
    expect(DramaChannelPreferences.lastType, -1);
  });

  test('load 读入当前与上一次的 tab_type', () async {
    SharedPreferences.setMockInitialValues({
      DramaChannelPreferences.key: 24,
      DramaChannelPreferences.lastKey: 16,
    });
    DramaChannelPreferences.reset();

    final preferences = await SharedPreferences.getInstance();
    DramaChannelPreferences.load(preferences);

    expect(DramaChannelPreferences.selectedType, 24);
    expect(DramaChannelPreferences.lastType, 16);
  });

  test('save 写回当前类型，并把上一次记成 last_tab_type', () async {
    final preferences = await SharedPreferences.getInstance();
    DramaChannelPreferences.load(preferences);

    // 第一次切换没有「上一个」：官方口径是 -1。
    await DramaChannelPreferences.save(16);
    expect(DramaChannelPreferences.selectedType, 16);
    expect(DramaChannelPreferences.lastType, -1);

    await DramaChannelPreferences.save(30);
    expect(DramaChannelPreferences.selectedType, 30);
    expect(DramaChannelPreferences.lastType, 16);

    final stored = await SharedPreferences.getInstance();
    expect(stored.getInt(DramaChannelPreferences.key), 30);
    expect(stored.getInt(DramaChannelPreferences.lastKey), 16);
  });

  test('重复保存同一类型不改写 last_tab_type', () async {
    final preferences = await SharedPreferences.getInstance();
    DramaChannelPreferences.load(preferences);

    await DramaChannelPreferences.save(16);
    await DramaChannelPreferences.save(16);

    expect(DramaChannelPreferences.selectedType, 16);
    expect(DramaChannelPreferences.lastType, -1);
  });

  test('reset 把内存态清回没有记录', () async {
    DramaChannelPreferences.selectedType = 30;
    DramaChannelPreferences.lastType = 16;

    DramaChannelPreferences.reset();

    expect(DramaChannelPreferences.selectedType, isNull);
    expect(DramaChannelPreferences.lastType, -1);
  });
}
