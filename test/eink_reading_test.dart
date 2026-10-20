import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/reader/eink_reading.dart';
import 'package:fqapp/services/reader_preferences.dart';

void main() {
  group('einkEffectiveTurnStyle', () {
    test('墨水屏强制 none，不管原翻页方式', () {
      for (final style in ReaderPageTurnStyle.values) {
        expect(
          einkEffectiveTurnStyle(
            eink: true,
            instantSwipeTurn: false,
            pageTurnStyle: style,
          ),
          ReaderPageTurnStyle.none,
        );
      }
    });

    test('非墨水屏时滑动直翻也强制 none', () {
      expect(
        einkEffectiveTurnStyle(
          eink: false,
          instantSwipeTurn: true,
          pageTurnStyle: ReaderPageTurnStyle.curl,
        ),
        ReaderPageTurnStyle.none,
      );
    });

    test('非墨水屏且未开直翻时透传原方式', () {
      expect(
        einkEffectiveTurnStyle(
          eink: false,
          instantSwipeTurn: false,
          pageTurnStyle: ReaderPageTurnStyle.curl,
        ),
        ReaderPageTurnStyle.curl,
      );
    });
  });

  group('einkEffectiveInstantSwipe', () {
    test('墨水屏强制直翻', () {
      expect(
        einkEffectiveInstantSwipe(eink: true, instantSwipeTurn: false),
        isTrue,
      );
    });

    test('非墨水屏透传用户开关', () {
      expect(
        einkEffectiveInstantSwipe(eink: false, instantSwipeTurn: false),
        isFalse,
      );
      expect(
        einkEffectiveInstantSwipe(eink: false, instantSwipeTurn: true),
        isTrue,
      );
    });
  });

  group('einkEffectiveFontWeight', () {
    test('墨水屏最低 500', () {
      expect(einkEffectiveFontWeight(eink: true, fontWeight: 300), 500);
      expect(einkEffectiveFontWeight(eink: true, fontWeight: 400), 500);
    });

    test('墨水屏保留用户更高的字重', () {
      expect(einkEffectiveFontWeight(eink: true, fontWeight: 600), 600);
    });

    test('非墨水屏透传', () {
      expect(einkEffectiveFontWeight(eink: false, fontWeight: 300), 300);
    });
  });

  group('einkDitherPixels', () {
    test('红蓝两像素：灰度 + 误差扩散到 16 档', () {
      // 红：0.299*255=76.245 → 量化 68，误差 8.245 扩给下一像素；
      // 蓝：0.114*255=29.07 + 8.245*7/16=32.677 → 量化 34。
      final out = einkDitherPixels(
        Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]),
        2,
        1,
      );
      expect(out, [68, 68, 68, 255, 34, 34, 34, 255]);
    });

    test('输出只有 16 档灰阶，Alpha 原样保留', () {
      final input = Uint8List.fromList([
        200, 100, 50, 128,
        10, 20, 30, 0,
        255, 255, 255, 255,
        0, 0, 0, 64,
      ]);
      final out = einkDitherPixels(input, 2, 2);
      for (var i = 0; i < out.length; i += 4) {
        // R/G/B 相同且是 17 的倍数（16 档：0,17,...,255）。
        expect(out[i], out[i + 1]);
        expect(out[i], out[i + 2]);
        expect(out[i] % 17, 0);
        expect(out[i + 3], input[i + 3]);
      }
    });
  });
}
