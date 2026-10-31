import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 朗读句高亮的自定义底色：默认跟随主题派生（null），选了固定色后能持久化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认不指定颜色，交给主题按背景派生', () {
    const preferences = ReaderPreferences();
    expect(preferences.narrationHighlightColor, isNull);
    expect(ReaderPreferences.narrationHighlightPresets, isNotEmpty);
  });

  test('选色后能存下来、读回来', () async {
    final color = ReaderPreferences.narrationHighlightPresets.first;
    final preferences = const ReaderPreferences()
        .copyWith(narrationHighlightColor: color);
    expect(preferences.narrationHighlightColor, color);

    await preferences.save();
    final loaded = await ReaderPreferences.load();
    expect(loaded.narrationHighlightColor, color);
  });

  test('改回自动会把记录清掉', () async {
    final color = ReaderPreferences.narrationHighlightPresets.last;
    await const ReaderPreferences()
        .copyWith(narrationHighlightColor: color)
        .save();
    expect((await ReaderPreferences.load()).narrationHighlightColor, color);

    final autoed = (await ReaderPreferences.load()).copyWith(
      autoNarrationHighlightColor: true,
    );
    expect(autoed.narrationHighlightColor, isNull);
    await autoed.save();
    expect((await ReaderPreferences.load()).narrationHighlightColor, isNull);
  });
}
