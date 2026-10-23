import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/category_front.dart';
import 'package:fqapp/pages/category_page.dart';

/// 官方分类页结构（KmpCategoryFragment）：左频道竖列 + 右分组瓦片，
/// 一次 GET 渲染全部。这里钉住：频道切换换内容、瓦片点击、空数据错误态。
void main() {
  CategoryFront front() => CategoryFront.fromPayload({
    'code': 0,
    'data': {
      'category_tab_config': {
        'tab_list': [
          {
            'category_tab': 1,
            'tab_name': '男频',
            'cell_data': [
              {
                'cell_name': '热门',
                'atom_data': [
                  {
                    'category_data': {
                      'name': '都市',
                      'pic_url': '',
                      'category_id': '101',
                      'category_landpage_url': '',
                    },
                  },
                  {
                    'category_data': {
                      'name': '玄幻',
                      'pic_url': '',
                      'category_id': '102',
                      'is_view_all': true,
                    },
                  },
                ],
              },
            ],
          },
          {
            'category_tab': 0,
            'tab_name': '女频',
            'cell_data': [
              {
                'cell_name': '热门',
                'atom_data': [
                  {
                    'category_data': {
                      'name': '古言',
                      'pic_url': '',
                      'category_id': '201',
                      'category_landpage_url': '',
                    },
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  });

  Future<void> pump(WidgetTester tester, CategoryFront f) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(home: CategoryPage(loader: ({int tab = 1}) async => f)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders channels, groups and tiles from the payload', (
    tester,
  ) async {
    await pump(tester, front());

    expect(find.text('男频'), findsOneWidget);
    expect(find.text('女频'), findsOneWidget);
    expect(find.text('热门'), findsOneWidget);
    expect(find.text('都市'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
  });

  testWidgets('switching the channel swaps the tiles', (tester) async {
    await pump(tester, front());

    expect(find.text('都市'), findsOneWidget);
    expect(find.text('古言'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('category_channel_1')));
    await tester.pumpAndSettle();

    expect(find.text('古言'), findsOneWidget);
    expect(find.text('都市'), findsNothing);
  });

  testWidgets('an empty payload shows the error view with retry', (
    tester,
  ) async {
    await pump(tester, CategoryFront.empty);

    expect(find.textContaining('分类暂时没有内容'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  test('payload parser keeps server shapes', () {
    final f = front();
    expect(f.channels.map((c) => c.name), ['男频', '女频']);
    expect(f.channels.first.groups.single.tiles, hasLength(2));
    expect(f.channels.first.groups.single.tiles.last.isViewAll, isTrue);
  });
}
