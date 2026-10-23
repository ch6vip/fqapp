import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/home_cell.dart';

/// 用真机抓到的 `build/home_raw.json` 验证解析层：顶栏分类与区块都要出来。
/// 这个文件是 2026-10-22 从 `/api/v1/recommend/homepage?tab_type=2` 抓的真实响应。
void main() {
  test('真实响应的 tab_item 与 cell_data 都能解析出来', () {
    final file = File('build/home_raw.json');
    if (!file.existsSync()) {
      markTestSkipped('缺少 build/home_raw.json（真机抓包样本）');
      return;
    }
    final payload = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final data = payload['data'] as Map<String, dynamic>;
    final tabItems = data['tab_item'] as List;

    // 顶栏：官方用服务端 title 当名字、tab_type 当身份。
    final titles = <String>[];
    Map<String, dynamic>? bookstore;
    for (final raw in tabItems) {
      final tab = raw as Map<String, dynamic>;
      final type = tab['tab_type'];
      final title = tab['title'];
      if (type is num && title is String && title.isNotEmpty) {
        titles.add(title);
      }
      if (type?.toString() == '2') bookstore = tab;
    }
    expect(titles, contains('推荐'));
    expect(titles, contains('小说'));
    expect(titles, contains('经典'));
    expect(titles, isNot(contains('漫剧'))); // 服务端根本没有这个分类
    expect(bookstore, isNotNull);

    final cells = parseHomeCells(bookstore!);
    expect(cells.length, 2);
    expect(cells[0].showType, 511); // RankCellV3 排行榜
    expect(cells[0].name, '排行榜');
    expect(cells[0].flatten().length, 16);
    expect(cells[1].showType, 384); // MultiTabMixedUnlimitedV2 猜你喜欢
    expect(cells[1].name, '猜你喜欢');
    expect(cells[1].flatten().length, greaterThanOrEqualTo(11));

    // 排行行的副标题：官方 TagLayout 渲染 secondary_info_list 的 content
    // （真机样本第一条是「多人二刷 / 9320万热度」），解析层必须保留。
    final firstRankBook = cells[0].flatten().first;
    expect(firstRankBook.rankTags, isNotEmpty);
    expect(firstRankBook.rankTags.first, '多人二刷');
    expect(firstRankBook.rankTags.last, contains('热度'));
  });
}
