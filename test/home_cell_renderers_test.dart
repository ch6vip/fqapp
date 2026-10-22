import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/widgets/home/home_cell_renderers.dart';

/// The dispatch layer that will host block widgets. Nothing is adopted yet, so
/// these cases pin the two properties that make adoption safe:
///
/// * an unregistered type never renders (the caller keeps its old pipeline);
/// * a registered type gets the block and can ask for the fallback.
void main() {
  HomeCell cellWith(int showType, {String name = ''}) => HomeCell(
    showType: showType,
    name: name,
    id: '',
    style: const {},
    items: const [],
    children: const [],
  );

  setUp(HomeCellRenderers.clear);
  tearDown(HomeCellRenderers.clear);

  testWidgets('an unregistered block type renders nothing', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );
    // 511/384 都是真实 feed 里出现过的类型，但都还没实现。
    for (final type in [511, 384, 385, 512, 339]) {
      expect(HomeCellRenderers.handles(type), isFalse, reason: 'type $type');
      expect(
        HomeCellRenderers.build(
          ctx,
          cellWith(type),
          fallback: () => const Text('fallback'),
        ),
        isNull,
        reason: 'type $type 未注册时调用方应沿用原渲染',
      );
    }
    expect(HomeCellRenderers.count, 0);
  });

  testWidgets('a registered type receives the block and the fallback', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );
    HomeCell? seen;
    var fallbackUsed = false;
    HomeCellRenderers.register(
      511,
      (context, cell, {required fallback}) {
        seen = cell;
        fallbackUsed = true;
        return const Text('排行榜');
      },
    );

    final widget = HomeCellRenderers.build(
      ctx,
      cellWith(511, name: '排行榜'),
      fallback: () => const Text('fallback'),
    );

    expect(HomeCellRenderers.handles(511), isTrue);
    expect(HomeCellRenderers.count, 1);
    expect(seen?.name, '排行榜');
    expect(fallbackUsed, isTrue);
    expect(widget, isA<Text>());
    // 其他类型不受影响。
    expect(HomeCellRenderers.handles(384), isFalse);
  });

  test('re-registering a type replaces it instead of adding a second one', () {
    var calls = 0;
    HomeCellRenderers.register(511, (c, cell, {required fallback}) {
      calls = 1;
      return const SizedBox();
    });
    HomeCellRenderers.register(511, (c, cell, {required fallback}) {
      calls = 2;
      return const SizedBox();
    });
    expect(HomeCellRenderers.count, 1);
    expect(calls, 0, reason: '注册本身不渲染');
  });

  test('the production table adopts nothing yet', () {
    registerDefaultHomeCells();
    // 这张表是「已采用」的清单；PR1 里它必须是空的，否则首页观感会变。
    expect(HomeCellRenderers.count, 0);
  });
}
