import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/wenku/glass_controls.dart';

/// 阅读设置面板在 wenku8 阅读界面移植后改成「分类卡片 → 分类内容」两层：
/// 打开面板先落在分类网格，控件都在各自的分类里。
///
/// 这些 helper 把那一层导航集中起来，用例只断言分类内的控件本身，不再关心
/// 面板是怎么拆的。
///
/// 默认面板（未注入 `onMarks`）的卡片；注入书签回调后还会多一个 `bookmarks`。
const readerSettingsCategories = <String>[
  'font',
  'paragraph',
  'page',
  'theme',
  'turn',
  'listening',
  'operations',
];

/// 分类卡片的标题，用于断言面板当前停在哪一层。
const readerSettingsCategoryTitles = <String, String>{
  'font': '字体',
  'paragraph': '段落',
  'page': '屏幕',
  'theme': '主题',
  'turn': '翻页',
  'listening': '听书',
  'operations': '操作',
  'bookmarks': '书签',
};

/// 点开某个分类卡片。
Future<void> openReaderSettingsCategory(WidgetTester tester, String id) async {
  final card = find.byKey(ValueKey('reader-settings-category-$id'));
  expect(card, findsOneWidget, reason: '设置面板里应有 $id 分类卡片');
  await tester.ensureVisible(card);
  await tester.pumpAndSettle();
  await tester.tap(card);
  await tester.pumpAndSettle();
}

/// 从分类内容退回分类网格，供同一个用例里跨分类断言。
Future<void> backToReaderSettingsCategories(WidgetTester tester) async {
  final back = find.byKey(const ValueKey('reader-settings-back'));
  expect(back, findsOneWidget, reason: '分类内容应提供返回网格的入口');
  await tester.tap(back);
  await tester.pumpAndSettle();
}

/// 关掉整个设置面板。分类网格与每个分类内容都有同一个关闭钮（key
/// `reader-settings-close`），所以不用猜当前标题。
Future<void> closeReaderSettingsSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('reader-settings-close')));
  await tester.pumpAndSettle();
}

/// 设置面板自身的滚动区；分类网格与每个分类内容各有一份。
Finder readerSettingsScroll([String category = 'grid']) =>
    find.byKey(ValueKey('reader-settings-scroll-$category'));

/// 面板里所有可调参数都是 [AppGlassSlider]（来自 wenku8 的 `AppControls`），
/// 不再是 Material `Slider`，也没有 +/- 步进器。直接驱动它的回调能拿到确定
/// 量值，效果等同于用户拖到该值后松手。
Future<void> setReaderSliderValue(
  WidgetTester tester,
  String sliderKey,
  double value,
) async {
  final finder = find.byKey(ValueKey(sliderKey));
  expect(finder, findsOneWidget, reason: '滑条 $sliderKey 应存在');
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  final slider = tester.widget<AppGlassSlider>(finder);
  slider.onChanged!(value);
  slider.onChangeEnd!(value);
  await tester.pumpAndSettle();
}
