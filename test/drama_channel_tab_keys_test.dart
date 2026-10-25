import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/services/desktop_platform.dart';

/// 频道条锚点的复用规则：服务端频道表替换本地表（条数变化）时只增删尾部。
///
/// 全部重建会让每个 `_ChannelTab` 的 Element 换新，大字号选中过渡动画被打断、
/// 整条频道条闪一下——这条规则现在抽成了纯函数，直接钉住。
void main() {
  test('条数不变时返回同一份列表', () {
    final keys = syncChannelTabKeys(const <GlobalKey>[], 3);
    expect(syncChannelTabKeys(keys, 3), same(keys));
  });

  test('条数变多时保留已有锚点，只给新增的 index 建 key', () {
    final keys = syncChannelTabKeys(const <GlobalKey>[], 3);
    final grown = syncChannelTabKeys(keys, 5);
    expect(grown, hasLength(5));
    for (var index = 0; index < 3; index++) {
      expect(grown[index], same(keys[index]), reason: 'index $index 的锚点不该重建');
    }
    expect(grown[3], isNot(same(grown[4])));
  });

  test('条数变少时保留前缀并截断尾部', () {
    final keys = syncChannelTabKeys(const <GlobalKey>[], 4);
    final shrunk = syncChannelTabKeys(keys, 2);
    expect(shrunk, hasLength(2));
    expect(shrunk[0], same(keys[0]));
    expect(shrunk[1], same(keys[1]));
  });

  /// 顶栏高度是「悬浮层」与「列表留白」共用的契约，单独钉住：移动端 =
  /// 搜索行 51 + 频道条；桌面端不含搜索行；大字号只抬高频道条那一段。
  Future<double> readTopChrome(WidgetTester tester, TextScaler scaler) async {
    late double height;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: const Size(400, 800), textScaler: scaler),
        child: Builder(
          builder: (context) {
            height = dramaTopChromeHeight(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return height;
  }

  testWidgets('顶栏高度 = 搜索行 + 频道条（桌面端不含搜索行）', (tester) async {
    final normal = await readTopChrome(tester, TextScaler.noScaling);
    expect(normal, isWindowsDesktop ? 38 : 89);

    // 2 倍字号：频道条 24×2×1.1+6 = 58.8 > 38 → 抬到 62.8。
    final large = await readTopChrome(tester, const TextScaler.linear(2));
    expect(large, closeTo(isWindowsDesktop ? 62.8 : 113.8, .01));
  });
}
