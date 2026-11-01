import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/rank.dart';
import 'package:fqapp/pages/rank_page.dart';
import 'package:fqapp/services/app_theme.dart' show einkModeNotifier;
import 'package:fqapp/widgets/home/home_chip.dart';
import 'package:fqapp/widgets/home/home_design.dart';
import 'package:fqapp/widgets/home/home_feed_states.dart';

/// 榜单页视觉对齐：层级用首页同款下划线文字 tab、分类用 HomeChip、
/// 空榜与失败分开（共享空/错态）、名次与流尾跟随色板。
const _catalog = RankCatalog(
  rankId: '7098235271900037133',
  tabs: [
    RankTab(name: '巅峰榜', algo: 200),
    RankTab(name: '完本榜', algo: 100),
  ],
  categories: [
    RankCategory(name: '全部', id: 0),
    RankCategory(name: '穿越', id: 37),
  ],
);

RankBoard _board({bool hasMore = false}) => RankBoard(
  hasMore: hasMore,
  entries: [
    for (var i = 1; i <= 4; i++)
      RankEntry(
        position: i,
        id: 'book-$i',
        title: '榜书$i',
        author: '作者$i',
        category: '传统玄幻',
        creationStatus: 1,
      ),
  ],
);

void main() {
  Future<void> pump(WidgetTester tester, {RankPageLoader? pageLoader}) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: RankPage(
          catalogLoader: () async => _catalog,
          pageLoader:
              pageLoader ??
              ({
                required rankId,
                required algo,
                required categoryId,
                required offset,
                required startAt,
              }) async => _board(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Text tabText(WidgetTester tester, int algo) => tester.widget<Text>(
    find.descendant(
      of: find.byKey(ValueKey('rank_tab_$algo')),
      matching: find.byType(Text),
    ),
  );

  testWidgets('榜单层级是下划线文字 tab，不是橙底胶囊', (tester) async {
    await pump(tester);
    const palette = HomePalette(false);

    expect(tester.getSize(find.byKey(const Key('rank_tabs'))).height, 44);
    final selected = tabText(tester, 200);
    expect(selected.style?.fontSize, 13);
    expect(selected.style?.fontWeight, FontWeight.w700);
    expect(selected.style?.color, palette.ink);
    final unselected = tabText(tester, 100);
    expect(unselected.style?.fontWeight, FontWeight.w500);
    expect(unselected.style?.color, palette.muted);

    // 文字 tab 视觉只有约 23dp 高，可点区域必须补到 44dp 高、48dp 宽，
    // 并且由 InkWell 承载：焦点遍历 + 键盘 Enter/Space 用它激活。
    final tabSize = tester.getSize(find.byKey(const ValueKey('rank_tab_200')));
    expect(tabSize.height, greaterThanOrEqualTo(44));
    expect(tabSize.width, greaterThanOrEqualTo(48));
    final inkWell = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('rank_tab_200')),
        matching: find.byType(InkWell),
      ),
    );
    expect(inkWell.canRequestFocus, isTrue);
  });

  testWidgets('tab 可键盘聚焦并用 Enter 激活切换', (tester) async {
    final requested = <int>[];
    await pump(
      tester,
      pageLoader:
          ({
            required rankId,
            required algo,
            required categoryId,
            required offset,
            required startAt,
          }) async {
            requested.add(algo);
            return _board();
          },
    );

    // 裸 GestureDetector 不在焦点遍历里；InkWell 的焦点节点应能收到
    // Enter 并走 onTap 切换榜单。
    final tabTextContext = tester.element(
      find.descendant(
        of: find.byKey(const ValueKey('rank_tab_100')),
        matching: find.byType(Text),
      ),
    );
    final focusNode = Focus.of(tabTextContext);
    expect(focusNode.canRequestFocus, isTrue);
    focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(requested, [200, 100]);
  });

  testWidgets('分类筛选统一为 HomeChip，点击仍按分类 id 请求', (tester) async {
    final requested = <int>[];
    await pump(
      tester,
      pageLoader:
          ({
            required rankId,
            required algo,
            required categoryId,
            required offset,
            required startAt,
          }) async {
            requested.add(categoryId);
            return _board();
          },
    );

    final chips = tester.widgetList<HomeChip>(find.byType(HomeChip)).toList();
    expect(chips, hasLength(2));
    expect(chips.first.selected, isTrue);
    expect(chips.last.selected, isFalse);

    await tester.tap(find.byKey(const ValueKey('rank_category_37')));
    await tester.pumpAndSettle();
    expect(requested, [0, 37]);
  });

  testWidgets('空榜显示空态而不是错误态', (tester) async {
    await pump(
      tester,
      pageLoader:
          ({
            required rankId,
            required algo,
            required categoryId,
            required offset,
            required startAt,
          }) async => RankBoard.empty,
    );

    expect(find.byKey(const Key('rank_empty')), findsOneWidget);
    expect(find.byType(HomeStateView), findsOneWidget);
    expect(find.text('该榜单暂无内容'), findsOneWidget);
    expect(find.text('刷新'), findsOneWidget);
    // 空不是错：不出现重试错误态。
    expect(find.byKey(const Key('rank_retry')), findsNothing);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('请求失败用共享错误态并可重试', (tester) async {
    var attempts = 0;
    await pump(
      tester,
      pageLoader:
          ({
            required rankId,
            required algo,
            required categoryId,
            required offset,
            required startAt,
          }) async {
            attempts++;
            if (attempts == 1) throw StateError('offline');
            return _board();
          },
    );

    expect(find.byKey(const Key('rank_retry')), findsOneWidget);
    expect(find.byType(HomeStateView), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('榜书1'), findsOneWidget);
  });

  testWidgets('前三名用强调文字色，第四名起是 muted', (tester) async {
    await pump(tester);
    const palette = HomePalette(false);

    expect(
      tester.widget<Text>(find.text('1')).style?.color,
      palette.accentText,
    );
    expect(tester.widget<Text>(find.text('4')).style?.color, palette.muted);
  });

  testWidgets('墨水屏：名次与选中 tab 退化为纯黑', (tester) async {
    einkModeNotifier.value = true;
    addTearDown(() => einkModeNotifier.value = false);
    await pump(tester);

    expect(tester.widget<Text>(find.text('1')).style?.color, Colors.black);
    expect(tabText(tester, 200).style?.color, Colors.black);
    expect(tabText(tester, 100).style?.color, Colors.black);
  });

  testWidgets('已到底的榜单用共享流尾的 done 文案', (tester) async {
    await pump(tester);
    expect(find.text('已显示全部内容'), findsOneWidget);
  });

  testWidgets('还有下一页时不预先显示流尾', (tester) async {
    await pump(
      tester,
      pageLoader:
          ({
            required rankId,
            required algo,
            required categoryId,
            required offset,
            required startAt,
          }) async => _board(hasMore: true),
    );
    expect(find.text('已显示全部内容'), findsNothing);
    expect(find.text('加载中...'), findsNothing);
  });
}
