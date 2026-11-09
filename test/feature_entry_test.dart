import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/wenku/src/archive_icons.dart';
import 'package:fqapp/widgets/wenku/wenku_feature.dart';

void _noop() {}

void main() {
  testWidgets(
    'a row that shows a value puts its chevron where every other row does',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(Brightness.light),
          home: const Scaffold(
            body: Column(
              children: [
                FeatureEntry(
                  title: '主题',
                  subtitle: '经典主题、档案主题',
                  icon: Icons.palette_outlined,
                  trailingText: '经典主题',
                  onTap: _noop,
                ),
                FeatureEntry(
                  title: '外观',
                  subtitle: '主题模式、OLED 纯黑',
                  icon: Icons.brightness_6_outlined,
                  onTap: _noop,
                ),
              ],
            ),
          ),
        ),
      );

      final finder = find.byWidgetPredicate(
        (w) =>
            w is ArchiveIcon &&
            (w.symbol == ArchiveSymbol.forward ||
                w.icon == CupertinoIcons.chevron_right),
      );
      expect(finder, findsNWidgets(2), reason: 'one chevron per row');

      final rects =
          finder
              .evaluate()
              .map(
                (e) => tester.getRect(find.byElementPredicate((x) => x == e)),
              )
              .toList()
            ..sort((a, b) => a.top.compareTo(b.top));

      expect(
        rects[0].left,
        rects[1].left,
        reason:
            'the chevron must sit at the same x whether the row shows a '
            'value or not',
      );
    },
  );

  testWidgets('a long value does not push the chevron off the edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: FeatureEntry(
                title: '主题',
                subtitle: '经典主题、档案主题',
                icon: Icons.palette_outlined,
                trailingText: '一个非常非常长的主题名称',
                onTap: _noop,
              ),
            ),
          ),
        ),
      ),
    );

    final chevron = find.byWidgetPredicate(
      (w) =>
          w is ArchiveIcon &&
          (w.symbol == ArchiveSymbol.forward ||
              w.icon == CupertinoIcons.chevron_right),
    );
    final rect = tester.getRect(chevron);
    final panelRect = tester.getRect(find.byType(FeatureEntry));
    expect(
      rect.right,
      lessThanOrEqualTo(panelRect.right),
      reason: 'the chevron must stay inside the row',
    );
    expect(
      rect.right,
      closeTo(panelRect.right, 24),
      reason: 'the chevron must sit at the trailing edge of the row',
    );
  });

  testWidgets('a row without a value keeps its full title width', (
    tester,
  ) async {
    // Guards the layout shape, not just the arrow: an earlier fix tried to
    // pin the chevron with a `Spacer` in the no-value branch, which split the
    // leftover with the title's `Expanded` and halved the subtitle. A plain
    // row must still give its title the whole width between icon and chevron.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: FeatureEntry(
                title: '短剧',
                subtitle: '播放、缓存与弹幕的全局开关，很长很长很长很长的副标题',
                icon: Icons.movie_outlined,
                onTap: _noop,
              ),
            ),
          ),
        ),
      ),
    );

    final subtitle = tester.getRect(find.textContaining('全局开关').first);
    // Row 360, panel pad 32, icon+gap 33, chevron+gap 22: the title column
    // gets ~273. A Spacer would cut it to ~136.
    expect(
      subtitle.width,
      greaterThan(250),
      reason: 'the title column must keep the whole leftover width',
    );
  });
}
