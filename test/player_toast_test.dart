import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/player/player_toast.dart';

/// 播放页自绘的轻量提示（替代 SnackBar）。
void main() {
  testWidgets('toast 不继承 MaterialApp 兜底的黄色双下划线', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => PlayerToast.show(context, '清晰度已成功切换至480P'),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pump();

    expect(find.text('清晰度已成功切换至480P'), findsOneWidget);
    final rich = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('player-toast')),
        matching: find.byType(RichText),
      ),
    );
    final style = rich.text.style!;
    // 根 Overlay 不在页面的 Material 之下；没有透明 Material 时会继承
    // MaterialApp 的 `_errorTextStyle`：黄色、double 下划线、w900 等宽。
    expect(style.decoration, isNot(TextDecoration.underline));
    expect(style.decorationStyle, isNot(TextDecorationStyle.double));
    expect(style.fontWeight, isNot(FontWeight.w900));
    expect(style.fontFamily, isNot('monospace'));
    // 提示自己的字号与颜色不受影响。
    expect(style.fontSize, 13);
    expect(style.color, Colors.white);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('清晰度已成功切换至480P'), findsNothing);
  });
}
