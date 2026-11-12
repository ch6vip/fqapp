import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/shell_visibility.dart';
import 'package:fqapp/widgets/lazy_indexed_stack.dart';

Widget _stack(int index) => Directionality(
  textDirection: TextDirection.ltr,
  child: LazyIndexedStack(
    index: index,
    children: const [Text('0'), Text('1'), Text('2')],
  ),
);

void main() {
  // 进程级单例：任何用例前后都必须复位，否则后续用例会读到残留下标
  // 被判成「隐藏」（分页定时器不启动、书架不补数据）。
  setUp(resetShellVisibility);
  tearDown(resetShellVisibility);

  test('resetShellVisibility 回到「没有壳层」', () {
    shellVisibleTab.value = 2;
    expect(shellVisibleTab.value, 2);

    resetShellVisibility();
    expect(shellVisibleTab.value, isNull);
  });

  testWidgets('LazyIndexedStack 挂载即广播当前下标', (tester) async {
    await tester.pumpWidget(_stack(1));

    expect(shellVisibleTab.value, 1);
  });

  testWidgets('换页广播新下标', (tester) async {
    await tester.pumpWidget(_stack(0));
    expect(shellVisibleTab.value, 0);

    await tester.pumpWidget(_stack(2));
    expect(shellVisibleTab.value, 2);
  });

  testWidgets('销毁时把「仍是自己写的值」复位成 null', (tester) async {
    await tester.pumpWidget(_stack(2));
    expect(shellVisibleTab.value, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(shellVisibleTab.value, isNull);
  });

  testWidgets('别的写入者已经改过时，销毁不要覆盖它', (tester) async {
    await tester.pumpWidget(_stack(1));
    // 模拟壳层/另一个容器接管了可见性。
    shellVisibleTab.value = 3;

    await tester.pumpWidget(const SizedBox.shrink());
    expect(shellVisibleTab.value, 3);
  });

  testWidgets('隐藏页不会收到「可见」信号（下标不一致）', (tester) async {
    final seen = <int?>[];
    void listener() => seen.add(shellVisibleTab.value);
    shellVisibleTab.addListener(listener);
    addTearDown(() => shellVisibleTab.removeListener(listener));

    await tester.pumpWidget(_stack(0));
    await tester.pumpWidget(_stack(1));
    await tester.pumpWidget(_stack(2));

    // 页面按 `value == 自己的 shellIndex` 判可见：这里只锁「广播序列」。
    expect(seen, [0, 1, 2]);
  });
}
