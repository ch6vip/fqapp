import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/drama_cache_preferences.dart';

List<Chapter> episodes(int count) => [
  for (var i = 0; i < count; i++)
    Chapter(itemId: 'ep$i', title: '第${i + 1}集', volumeName: ''),
];

List<String> ids(List<Chapter> list) => [
  for (final episode in list) episode.itemId,
];

/// 「边看边往后缓存」的取集范围：从当前集的**下一集**起算，不含当前集。
void main() {
  test('从当前集往后取指定集数', () {
    expect(
      ids(autoCacheEpisodes(episodes: episodes(8), currentIndex: 2, ahead: 5)),
      ['ep3', 'ep4', 'ep5', 'ep6', 'ep7'],
    );
  });

  test('末尾不足时按剩余集数取，不越界', () {
    expect(
      ids(autoCacheEpisodes(episodes: episodes(8), currentIndex: 5, ahead: 5)),
      ['ep6', 'ep7'],
    );
  });

  test('最后一集没有下一集可缓存', () {
    expect(
      autoCacheEpisodes(episodes: episodes(8), currentIndex: 7, ahead: 5),
      isEmpty,
    );
  });

  test('关闭（0 集）或空列表都不取', () {
    expect(
      autoCacheEpisodes(episodes: episodes(8), currentIndex: 3, ahead: 0),
      isEmpty,
    );
    expect(
      autoCacheEpisodes(episodes: const [], currentIndex: 0, ahead: 5),
      isEmpty,
    );
  });

  test('越界的当前集不会倒取（负数起点按空处理）', () {
    expect(
      autoCacheEpisodes(episodes: episodes(3), currentIndex: -5, ahead: 5),
      isEmpty,
    );
  });
}
