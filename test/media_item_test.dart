import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';

void main() {
  test('parses list-shaped chapterListWithVolume', () {
    final payload = {
      'code': 200,
      'data': {
        'data': {
          'chapterListWithVolume': [
            [
              {'itemId': 'c1', 'title': '第一章', 'volume_name': '正文'},
              {'itemId': 'c2', 'title': '第二章'},
            ],
          ],
        },
      },
    };

    final volumes = parseDirectory(payload);
    expect(volumes, hasLength(1));
    expect(volumes.first.map((c) => c.itemId), ['c1', 'c2']);
    expect(volumes.first.first.volumeName, '正文');
  });

  test('parses raw short-drama episodes as chapters', () {
    final payload = {
      'data': {
        'episodes': [
          {'video_id': 'v1', 'title': '第1集'},
          {'item_id': 'v2'},
        ],
      },
    };

    final chapters = parseDirectory(payload).expand((v) => v).toList();
    expect(chapters.map((c) => c.itemId), ['v1', 'v2']);
    expect(chapters.map((c) => c.title), ['第1集', '第2集']);
  });

  test('parses a direct array directory response', () {
    final payload = {
      'code': 200,
      'data': [
        {'item_id': 'c1', 'title': '第一章'},
        {'item_id': 'c2', 'title': '第二章'},
      ],
    };
    final chapters = parseDirectory(payload).expand((v) => v).toList();
    expect(chapters.map((c) => c.itemId), ['c1', 'c2']);
  });

  test('omits non-addressable rows from every supported directory shape', () {
    final entries = [
      {'title': '缺失 ID'},
      {'item_id': '   '},
      {'item_id': '0'},
      {'item_id': 0},
      {'item_id': ' c1 ', 'title': '可阅读章节'},
    ];
    for (final data in [
      entries,
      {
        'chapterListWithVolume': [entries],
      },
      {'episodes': entries},
    ]) {
      final chapters = parseDirectory({'data': data}).expand((v) => v).toList();
      expect(chapters.map((chapter) => chapter.itemId), ['c1']);
    }
  });

  test('parses legacy chapter IDs in a nested array envelope', () {
    final chapters = parseDirectory({
      'data': {
        'data': [
          {'chapter_id': 'chapter-1', 'title': '第一章'},
        ],
      },
    }).expand((v) => v).toList();
    expect(chapters.single.itemId, 'chapter-1');
  });

  test('keeps the volume container name in an unwrapped directory', () {
    final volumes = parseDirectory({
      'chapterListWithVolume': [
        {
          'volume_name': '第一卷',
          'chapterList': [
            {'itemId': 'c1', 'title': '第一章'},
          ],
        },
      ],
    });
    expect(volumes.single.single.volumeName, '第一卷');
  });

  test('prefers video id over book id for short dramas', () {
    final item = MediaItem.fromRaw({
      'book_id': 'series-book',
      'video_id': 'series-video',
      'cell_name': '短剧',
      'category': '短剧',
    });
    expect(item.kind, 'video');
    expect(item.id, 'series-video');
  });

  test('merges parent metadata into nested video search results', () {
    final tabs = parseSearchTabs({
      'data': {
        'search_tabs': [
          {
            'title': '短剧',
            'data': [
              {
                'series_id': 's1',
                // cell_name is the category label; the real title lives in
                // the nested video_data entry.
                'cell_name': '番茄短剧',
                'video_data': [
                  {'video_id': 'v1', 'title': '初次沦陷'},
                ],
              },
            ],
          },
        ],
      },
    });
    expect(tabs.single.items.single.id, 's1');
    expect(tabs.single.items.single.seriesId, 's1');
    expect(tabs.single.items.single.kind, 'video');
    expect(tabs.single.items.single.title, '初次沦陷');
  });

  test('filters profile and related-query cells from search results', () {
    final tabs = parseSearchTabs({
      'data': {
        'search_tabs': [
          {
            'title': '综合',
            'data': [
              {
                'cell_id': 'profile-cell',
                'cell_name': '萝莉',
                'show_type': 132,
                'search_user_data': [
                  {'is_author': false},
                ],
              },
              {
                'book_id': '104',
                'cell_id': 'community-cell',
                'cell_name': '社区',
                'show_type': 152,
                'cell_data': const [],
              },
              {
                'cell_id': 'book-cell',
                'show_type': 110,
                'book_data': [
                  {'book_id': 'b1', 'book_name': '无封面作品'},
                ],
              },
              {
                'cell_id': 'related-query-cell',
                'cell_name': '相关搜索',
                'show_type': 300,
                'guess_you_like_data': [
                  {'text': '魔女'},
                ],
              },
            ],
          },
        ],
      },
    });

    expect(tabs.single.items, hasLength(1));
    expect(tabs.single.items.single.id, 'b1');
    expect(tabs.single.items.single.title, '无封面作品');
    expect(tabs.single.items.single.cover, isEmpty);
  });

  test('keeps a legacy flat media search result', () {
    final tabs = parseSearchTabs({
      'data': {
        'search_tabs': [
          {
            'title': '书籍',
            'data': [
              {'book_id': 'b1', 'book_name': '扁平结构作品', 'author': '作者'},
            ],
          },
        ],
      },
    });

    expect(tabs.single.items, hasLength(1));
    expect(tabs.single.items.single.id, 'b1');
    expect(tabs.single.items.single.title, '扁平结构作品');
  });

  test('keeps explicit kind when restoring saved media', () {
    final item = MediaItem.fromRaw({
      'id': 'series-1',
      'title': '已保存短剧',
      'kind': 'video',
      'seriesId': 'series-1',
      'episodeId': 'episode-1',
    });
    expect(item.kind, 'video');
    expect(item.id, 'series-1');
    expect(item.episodeId, 'episode-1');
  });

  test('normalizes localized explicit media kinds', () {
    final item = MediaItem.fromRaw({
      'id': 'series-2',
      'title': '短剧',
      'kind': '短剧',
    });
    expect(item.kind, 'video');
    expect(item.id, 'series-2');
  });

  test('restores all normalized media metadata', () {
    final original = MediaItem(
      id: 'saved-book',
      title: '已保存作品',
      cover: '/covers/book.jpg',
      author: '作者',
      badge: '悬疑',
      ep: '120',
      kind: 'book',
    );

    expect(MediaItem.fromRaw(original.toJson()).toJson(), original.toJson());
  });

  test('explicit media kinds take precedence over upstream hints', () {
    for (final kind in ['book', 'manga', 'audio']) {
      final item = MediaItem.fromRaw({
        'book_id': 'work-1',
        'title': '作品',
        'kind': kind,
        'video_id': 'preview-video',
        'category': '短剧',
        'duration': 100,
      });

      expect(item.kind, kind);
      expect(item.id, 'work-1');
      expect(item.seriesId, isNull);
      expect(item.episodeId, isNull);
    }
  });

  test('audio duration alone does not identify a video', () {
    final item = MediaItem.fromRaw({
      'audio_book_id': 'audio-1',
      'title': '有声书',
      'duration': 1200,
    });

    expect(item.kind, 'audio');
    expect(item.id, 'audio-1');
  });

  test('preserves every work in a grouped book search cell', () {
    final tabs = parseSearchTabs({
      'data': {
        'search_tabs': [
          {
            'title': '书籍',
            'data': [
              {
                'cell_name': '相关作品',
                'category': '悬疑',
                'book_data': [
                  {'book_id': 'b1', 'book_name': '作品一'},
                  {'book_id': 'b2', 'book_name': '作品二'},
                ],
              },
            ],
          },
        ],
      },
    });

    expect(tabs.single.items.map((item) => item.id), ['b1', 'b2']);
    expect(tabs.single.items.map((item) => item.title), ['作品一', '作品二']);
    expect(tabs.single.items.map((item) => item.badge), ['悬疑', '悬疑']);
  });

  test('keeps a legacy parent ID when book_data contains only metadata', () {
    final tabs = parseSearchTabs({
      'data': {
        'search_tabs': [
          {
            'title': '书籍',
            'data': [
              {
                'book_id': 'b1',
                'title': '作品一',
                'book_data': [
                  {'author': '作者', 'thumb_url': '/cover.jpg'},
                ],
              },
            ],
          },
        ],
      },
    });

    expect(tabs.single.items.single.id, 'b1');
    expect(tabs.single.items.single.author, '作者');
  });

  test('novel cards with audio_thumb_uri stay books', () {
    // The audio recommend tab marks cards via the audio cover field, but
    // ordinary novel cards in the default feed have that field too — it must
    // NOT be treated as an audio signal.
    final item = MediaItem.fromRaw({
      'book_id': '7212512693792541734',
      'book_name': '官场之绝对权力',
      'audio_thumb_uri': 'https://p3-novel.byteimg.com/origin/novel-static/xxx',
      'category': '都市日常',
    });
    expect(item.kind, 'book');
    expect(item.title, '官场之绝对权力');
  });

  test('directory fallback episodes parse as video chapters', () {
    // The pseries player endpoint is dead for recommend series ids; the
    // backend now answers with the reading directory shape. The directory
    // parser must surface those rows as playable episodes (itemId = vid).
    final payload = {
      'code': 0,
      'data': {
        'book_info': {'book_name': '我家后山藏真龙'},
        'item_data_list': [
          {'item_id': '7678039365922065433', 'title': '第81集'},
          {'item_id': '7678039314705419289', 'title': '第82集'},
        ],
        'item_list': [
          {'item_id': 'x', 'title': 'x'},
        ],
      },
    };
    final volumes = parseDirectory(payload);
    final flat = volumes.expand((v) => v).toList();
    expect(flat.length, 2);
    expect(flat[0].itemId, '7678039365922065433');
    expect(flat[0].title, '第81集');
    expect(flat[1].itemId, '7678039314705419289');
  });

  test('directory fallback via bridge chapterListWithVolume', () {
    // The /api/directory?tab=短剧 bridge nests the normalized episodes under
    // payload.data.data.chapterListWithVolume — same shape novels use.
    final payload = {
      'code': 200,
      'data': {
        'data': {
          'chapterListWithVolume': [
            [
              {
                'itemId': '7678039365922065433',
                'item_id': '7678039365922065433',
                'title': '第81集',
                'volume_name': '剧集',
              },
              {
                'itemId': '7678039314705419289',
                'item_id': '7678039314705419289',
                'title': '第82集',
              },
            ],
          ],
        },
      },
    };
    final volumes = parseDirectory(payload);
    final flat = volumes.expand((v) => v).toList();
    expect(flat.length, 2);
    expect(flat.first.itemId, '7678039365922065433');
    expect(flat.first.title, '第81集');
  });

  test('extracts nested recommendation cards', () {
    final items = parseMediaItems({
      'code': 0,
      'data': {
        'tab_item': [
          {
            'cell_data': [
              {
                'cell_data': [
                  {
                    'book_data': [
                      {'book_id': 'b1', 'book_name': '推荐小说'},
                    ],
                  },
                ],
              },
            ],
          },
        ],
      },
    });
    expect(items.single.id, 'b1');
    expect(items.single.title, '推荐小说');
  });
}
