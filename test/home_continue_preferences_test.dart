import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/home_continue_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「继续阅读」关闭开关：只关掉被点的那一本，且跨重启记住。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HomeContinuePreferences.instance.resetForTest();
  });

  MediaItem book(String id) => MediaItem(
    id: id,
    title: '书',
    cover: '',
    author: '',
    badge: '',
    ep: '',
    kind: 'book',
  );

  test('关闭只对那一本生效，换书后这一行会重新出现', () async {
    final prefs = HomeContinuePreferences.instance;
    await prefs.load();
    expect(prefs.isDismissed(book('b1')), isFalse);

    await prefs.dismiss(book('b1'));
    expect(prefs.isDismissed(book('b1')), isTrue);
    expect(prefs.isDismissed(book('b2')), isFalse);
  });

  test('关闭记在 SharedPreferences 里，重启后仍然关着', () async {
    final prefs = HomeContinuePreferences.instance;
    await prefs.load();
    await prefs.dismiss(book('b9'));

    prefs.resetForTest();
    expect(prefs.isDismissed(book('b9')), isFalse);
    await prefs.load();
    expect(prefs.isDismissed(book('b9')), isTrue);
  });
}
