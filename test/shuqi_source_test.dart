import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/shuqi_book.dart';
import 'package:fqapp/pages/search_page.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('MediaItem defaults to fanqie and keeps source through copyWith', () {
    final item = MediaItem(
      id: '1',
      title: 't',
      cover: '',
      author: '',
      badge: '',
      ep: '',
      kind: 'book',
    );
    expect(item.source, 'fanqie');
    expect(item.copyWith(title: 'x').source, 'fanqie');

    final shuqi = item.copyWith(source: shuqiSourceId);
    expect(isShuqiItem(shuqi), isTrue);
    // copyWith 必须保留来源，否则点进详情会被当成番茄书。
    expect(shuqi.copyWith(title: 'y').source, shuqiSourceId);
  });

  test('a shuqi item keeps its source through a JSON round trip', () {
    final item = shuqiMediaItemFromSearch({
      'bookId': '34078',
      'name': '凡人修仙传',
      'author': '忘语',
      'coverUrl': '',
      'intro': '',
      'kind': '玄幻',
    });
    final restored = MediaItemJson.fromJson(item.toJson());
    expect(restored, isNotNull);
    expect(restored!.id, '34078');
    // 落盘后仍是书旗条目，恢复时不能被当成番茄书。
    expect(restored.source, shuqiSourceId);

    // 旧缓存没有 source 字段：缺省按番茄处理。
    final legacy = MediaItemJson.fromJson({
      'id': '1',
      'title': '旧数据',
      'kind': 'book',
    });
    expect(legacy!.source, 'fanqie');
  });

  test('a search payload becomes a shuqi MediaItem', () {
    final item = shuqiMediaItemFromSearch({
      'bookId': '34078',
      'name': '凡人修仙传',
      'author': '忘语',
      'coverUrl': 'https://img/34078.jpg',
      'intro': '一个普通山村小子',
      'wordCount': '2451万字',
      'status': '完结',
      'kind': '玄幻,修仙,完结',
    });
    expect(item.id, '34078');
    expect(item.title, '凡人修仙传');
    expect(item.author, '忘语');
    expect(item.kind, 'book');
    expect(item.source, shuqiSourceId);
    expect(item.categories, ['玄幻', '修仙', '完结']);
  });

  test('toc payload keeps chapter ids and converts to reader chapters', () {
    final toc = ShuqiToc.fromJson({
      'path': 'h5',
      'total': 2,
      'chapters': [
        {'chapterId': '2180322', 'title': '第1章 山边小村', 'isVip': false},
        {'chapterId': '2180323', 'title': '第2章 惊变', 'isVip': true},
      ],
    });
    expect(toc.hasRealTitles, isTrue);
    expect(toc.chapters, hasLength(2));
    expect(toc.chapters[1].isVip, isTrue);

    final rows = toc.toReaderChapters();
    expect(rows.map((chapter) => chapter.itemId), ['2180322', '2180323']);
    expect(rows.first.title, '第1章 山边小村');
  });

  test('the index fallback is reported as placeholder titles', () {
    final toc = ShuqiToc.fromJson({
      'path': 'index',
      'total': 1,
      'chapters': [
        {'chapterId': '9', 'title': '第1章', 'isVip': false},
      ],
    });
    expect(toc.hasRealTitles, isFalse);
    expect(toc.total, 1);
  });

  testWidgets('switching to shuqi searches it and renders its books', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          searchLoader:
              (query, {required int tabType, required int offset}) async {
                return const <SearchTab>[];
              },
          shuqiSearchLoader: (key) async {
            calls.add(key);
            return {
              'source': 'shuqi',
              'data': [
                {
                  'bookId': '34078',
                  'name': '凡人修仙传',
                  'author': '忘语',
                  'coverUrl': '',
                  'intro': '',
                  'wordCount': '2451万字',
                  'status': '完结',
                  'lastChapter': '第2451章',
                  'kind': '玄幻',
                },
              ],
            };
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('search-shuqi-source')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '凡人');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(calls, ['凡人']);
    expect(find.text('凡人修仙传'), findsOneWidget);
    // 分类页签在书旗模式下不参与选中，数量仍是番茄那 6 个。
    expect(find.byType(ChoiceChip), findsNWidgets(6));
  });

  testWidgets('a restored rating filter does not hide shuqi results', (
    tester,
  ) async {
    // 评分阈值从本地恢复为 9 分；书旗条目没有评分，不能被它过滤。
    SharedPreferences.setMockInitialValues({
      'search_minimum_score': 9.0,
      'search_list_view': false,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SearchPage(
          searchLoader:
              (query, {required int tabType, required int offset}) async {
                return const <SearchTab>[];
              },
          shuqiSearchLoader: (key) async {
            return {
              'source': 'shuqi',
              'data': [
                {
                  'bookId': '34078',
                  'name': '凡人修仙传',
                  'author': '忘语',
                  'coverUrl': '',
                  'intro': '',
                  'wordCount': '2451万字',
                  'status': '完结',
                  'lastChapter': '第2451章',
                  'kind': '玄幻',
                },
              ],
            };
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('search-shuqi-source')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '凡人');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('凡人修仙传'), findsOneWidget);
    expect(find.text('已加载结果中暂无达到评分的作品'), findsNothing);
  });
}
