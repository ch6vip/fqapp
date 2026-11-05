import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/shelf_identity.dart';
import 'package:fqapp/widgets/wenku/src/archive_shelf_entry.dart';

MediaItem _item({
  String id = '123',
  String kind = 'book',
  String source = 'fanqie',
  String author = '作者甲',
  String ep = '',
  int creationStatus = -1,
  String? seriesId,
}) => MediaItem(
  id: id,
  title: '书名$id',
  cover: '',
  author: author,
  badge: '',
  ep: ep,
  kind: kind,
  creationStatus: creationStatus,
  seriesId: seriesId,
  source: source,
);

void main() {
  test('identity 使用源限定键，与 ShelfIdentity 存储键同源', () {
    final fanqie = ArchiveShelfEntry(item: _item());
    expect(fanqie.contentKey, 'book:123');
    expect(fanqie.identity, fanqie.contentKey);
    expect(shelfStorageKeyOf(fanqie.item), 'shelf_v1:book:123');

    final shuqi = ArchiveShelfEntry(item: _item(source: 'shuqi'));
    expect(shuqi.identity, 'shuqi/book:123');
    expect(shelfStorageKeyOf(shuqi.item), 'shelf_v1:shuqi/book:123');

    final drama = ArchiveShelfEntry(
      item: _item(kind: 'video', seriesId: '9', id: '7'),
    );
    expect(drama.identity, 'video:9');
  });

  test('整书进度原样透传，不按章节重算', () {
    final entry = ArchiveShelfEntry(
      item: _item(),
      read: true,
      fraction: .37,
      chapterLabel: '第6章 · 共10章',
      totalChapters: 10,
    );
    expect(entry.fraction, .37);
    expect(entry.progressText, '第6章 · 共10章');
  });

  test('creationStatus 未知时不冒充连载状态', () {
    expect(ArchiveShelfEntry(item: _item()).statusLabel, isNull);
    expect(
      ArchiveShelfEntry(item: _item(creationStatus: 0)).statusLabel,
      '已完结',
    );
    expect(
      ArchiveShelfEntry(item: _item(creationStatus: 1)).statusLabel,
      '连载中',
    );
    expect(
      ArchiveShelfEntry(item: _item(creationStatus: 4)).statusLabel,
      isNull,
    );
  });

  test('subtitleLine 与 detailLine', () {
    final normal = ArchiveShelfEntry(
      item: _item(author: '作者甲', creationStatus: 1),
    );
    expect(normal.subtitleLine, '作者甲 · 连载中');
    expect(normal.detailLine, normal.subtitleLine);

    final withProgress = ArchiveShelfEntry(
      item: _item(author: '作者甲', creationStatus: 1),
      read: true,
      chapterLabel: '第2章 · 共9章',
    );
    expect(withProgress.detailLine, '第2章 · 共9章');

    expect(
      ArchiveShelfEntry(
        item: _item(author: '', creationStatus: 0),
      ).subtitleLine,
      '已完结',
    );
  });

  test('视频状态与副标题使用集数', () {
    final video = ArchiveShelfEntry(
      item: _item(kind: 'video', ep: '20'),
    );
    expect(video.isVideo, isTrue);
    expect(video.statusLabel, '20');
    expect(video.subtitleLine, '作者甲 · 全20集');
    expect(video.detailLine, '作者甲 · 全20集');

    final manju = ArchiveShelfEntry(
      item: _item(kind: 'manju', ep: ''),
    );
    expect(manju.isVideo, isTrue);
    expect(manju.statusLabel, isNull);
    expect(manju.subtitleLine, '作者甲');
  });

  test('视频 ep 已是集数文案时原样展示，不重复包裹', () {
    // `series_detail_page` stores `episodeLabel` (`全66集`).
    final labelled = ArchiveShelfEntry(
      item: _item(kind: 'video', ep: '全12集'),
    );
    expect(labelled.statusLabel, '全12集');
    expect(labelled.subtitleLine, '作者甲 · 全12集');
    expect(labelled.detailLine, '作者甲 · 全12集');

    // `drama_page` stores `共 N 集`.
    final drama = ArchiveShelfEntry(
      item: _item(kind: 'manju', ep: '共20集'),
    );
    expect(drama.subtitleLine, '作者甲 · 共20集');
    expect(drama.detailLine, '作者甲 · 共20集');
  });

  test('封面徽标顺序：更新/缓存在前，来源随后', () {
    expect(
      ArchiveShelfEntry(
        item: _item(source: 'shuqi'),
        sourceLabel: '书旗',
      ).coverBadges,
      ['书旗'],
    );
    expect(
      ArchiveShelfEntry(
        item: _item(),
        sourceLabel: '番茄',
        updated: true,
      ).coverBadges,
      ['更新', '番茄'],
    );
    expect(
      ArchiveShelfEntry(
        item: _item(),
        sourceLabel: '番茄',
        cached: true,
      ).coverBadges,
      ['缓存', '番茄'],
    );
    expect(
      ArchiveShelfEntry(
        item: _item(),
        updated: true,
        cached: true,
        sourceLabel: '番茄',
      ).coverBadges,
      ['更新', '番茄'],
    );
  });

  test('fileCode 沿用搜索页 FQ-/SQ- 约定', () {
    expect(ArchiveShelfEntry(item: _item(id: '123')).fileCode, 'FQ-00123');
    expect(
      ArchiveShelfEntry(
        item: _item(id: '123', source: 'shuqi'),
      ).fileCode,
      'SQ-00123',
    );
    expect(
      ArchiveShelfEntry(item: _item(id: 'local_1_ab')).fileCode,
      'FQ-local_1_ab',
    );
    expect(ArchiveShelfEntry(item: _item(id: '')).fileCode, 'FQ-UNFILED');
  });

  test('父类字段与未知类型不抛错', () {
    final unknown = ArchiveShelfEntry(item: _item(kind: 'unknown'));
    expect(unknown.subtitleLine, '作者甲');
    expect(unknown.progressText, '尚未开始阅读');
  });

  test('progressText 覆盖未读/已读完/共 N 章', () {
    expect(ArchiveShelfEntry(item: _item()).progressText, '尚未开始阅读');
    expect(
      ArchiveShelfEntry(item: _item(), read: true, finished: true).progressText,
      '已读完',
    );
    expect(
      ArchiveShelfEntry(
        item: _item(),
        read: true,
        totalChapters: 84,
      ).progressText,
      '共84章',
    );
    // Contract is four states; a read entry without chapter info reports no
    // progress instead of inventing a fifth label.
    expect(ArchiveShelfEntry(item: _item(), read: true).progressText, isEmpty);
  });

  test('archiveSourceLabel 映射来源与媒介', () {
    expect(archiveSourceLabel(_item(), local: false), '番茄');
    expect(archiveSourceLabel(_item(source: 'shuqi'), local: false), '书旗');
    expect(archiveSourceLabel(_item(kind: 'video'), local: false), '短剧');
    expect(archiveSourceLabel(_item(kind: 'manju'), local: false), '漫剧');
    expect(archiveSourceLabel(_item(source: 'shuqi'), local: true), '本地');
  });
}
