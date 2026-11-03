import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_listen_button.dart';
import 'package:fqapp/widgets/reader/reader_theme.dart';
import 'package:fqapp/widgets/reader/reader_video_button.dart';

/// 阅读页右下角两颗动作钮的直径守卫。
///
/// 它们照官方资源原本是 56dp，比听书胶囊里那圈圆形封面（42dp）大出三分
/// 之一，压在正文上显得重。这里把「与胶囊封面同尺寸」钉住：以后谁想改回
/// 56，得先改 [kReaderActionSize] 并面对这条断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  testWidgets('听书钮与胶囊封面同尺寸', (tester) async {
    await tester.pumpWidget(
      host(
        ReaderListenButton(
          preset: ReaderThemePreset.light,
          loading: false,
          unavailable: false,
          onTap: () {},
        ),
      ),
    );
    await tester.pump();

    expect(kReaderActionSize, 42);
    expect(
      tester.getSize(find.byType(ReaderListenButton)),
      const Size.square(kReaderActionSize),
    );
  });

  testWidgets('看剧钮收起时同尺寸，展开只加宽不改高', (tester) async {
    final visibility = ValueNotifier<bool>(true);
    addTearDown(visibility.dispose);
    await tester.pumpWidget(
      host(
        ReaderVideoButton(
          menuVisibility: visibility,
          preset: ReaderThemePreset.light,
          // 空封面：不拉网络图，也就没有「封面加载完才展开」的引导动画。
          cover: '',
          loading: false,
          onTap: () {},
        ),
      ),
    );
    await tester.pump();

    final size = tester.getSize(find.byType(ReaderVideoButton));
    expect(size.height, kReaderActionSize);
    expect(size.width, kReaderActionSize);
  });

  testWidgets('墨水屏「听」字号贴住圆内接上界', (tester) async {
    await tester.pumpWidget(
      host(
        ReaderListenButton(
          preset: ReaderThemePreset.eink,
          loading: false,
          unavailable: false,
          onTap: () {},
        ),
      ),
    );
    await tester.pump();

    final text = tester.widget<Text>(find.text('听'));
    final fontSize = text.style!.fontSize!;
    expect(fontSize, 28);
    // 字框四角离圆心 = 字号×√2/2，超出半径就会被 CircleBorder 裁掉。
    // 42 圆的内接正方形边长只有 42/√2 ≈ 29.7，这同时是字号的上界。
    expect(fontSize * math.sqrt2 / 2, lessThanOrEqualTo(kReaderActionSize / 2));
  });

  testWidgets('墨水屏「看」与「听」同字号', (tester) async {
    final visibility = ValueNotifier<bool>(true);
    addTearDown(visibility.dispose);
    await tester.pumpWidget(
      host(
        ReaderVideoButton(
          menuVisibility: visibility,
          preset: ReaderThemePreset.eink,
          cover: '',
          loading: false,
          onTap: () {},
        ),
      ),
    );
    await tester.pump();

    expect(tester.widget<Text>(find.text('看')).style?.fontSize, 28);
  });
}
