import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/widgets/home/home_chip.dart';
import 'package:fqapp/widgets/home/home_feed_states.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.createTheme(Brightness.light),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('HomeStateView scrollable 在受限高度里居中并可滚动', (tester) async {
    await tester.pumpWidget(
      _app(
        SizedBox(
          key: const Key('state-box'),
          width: 240,
          height: 120,
          child: HomeStateView(
            key: const Key('state-scrollable'),
            icon: LucideIcons.cloud_off,
            title: '加载失败',
            message: '上游返回了一段很长的说明文字，窄屏大字号下也要能滚动到重试按钮',
            actionLabel: '重试',
            onAction: () {},
            scrollable: true,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const Key('state-scrollable')),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
    expect(find.text('重试'), findsOneWidget);
    // 居中：滚动视图在 240×120 的框里垂直居中。
    expect(
      tester.getRect(find.byType(SingleChildScrollView)).center.dy,
      closeTo(tester.getRect(find.byKey(const Key('state-box'))).center.dy, 1),
    );
  });

  testWidgets('Wrap 里的 HomeChip 收缩到胶囊宽度而不是撑满整行', (tester) async {
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 320,
          child: Wrap(
            spacing: 8,
            children: [
              HomeChip(
                key: const Key('wrap-chip-a'),
                label: '全部级别',
                selected: true,
                onTap: () {},
              ),
              HomeChip(
                key: const Key('wrap-chip-b'),
                label: '调试',
                selected: false,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    final a = tester.getSize(find.byKey(const Key('wrap-chip-a')));
    final b = tester.getSize(find.byKey(const Key('wrap-chip-b')));
    // 两个 chip 都远窄于 320 的可用宽，且落在同一行。
    expect(a.width, lessThan(160));
    expect(b.width, lessThan(160));
    expect(
      tester.getRect(find.byKey(const Key('wrap-chip-a'))).top,
      tester.getRect(find.byKey(const Key('wrap-chip-b'))).top,
    );
    expect(a.height, greaterThanOrEqualTo(HomeChip.minTapTarget));
  });
}
