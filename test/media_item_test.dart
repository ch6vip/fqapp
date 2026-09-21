import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';

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

  group('novel item_data_list', () {
    // Live shape: the reading directory nests chapters under `item_data_list`,
    // each with its own volume_name and content version.
    Map<String, dynamic> payload() => {
      'code': 0,
      'data': {
        'item_data_list': [
          {
            'item_id': 'c1',
            'title': '第1章',
            'volume_name': '第一卷：默认',
            'version': 'abc_1_def',
          },
          {
            'item_id': 'c2',
            'title': '第2章',
            'volume_name': '第一卷：默认',
            'version': 'ghi_1_jkl',
          },
        ],
      },
    };

    test('keeps the chapter version the paragraph comments need', () {
      final chapters = parseDirectory(payload()).expand((v) => v).toList();
      expect(chapters.map((c) => c.version), ['abc_1_def', 'ghi_1_jkl']);
    });

    test('keeps the real volume name instead of the drama placeholder', () {
      // This list used to be read with the episode parser, which hardcodes
      // `剧集` and drops the version — so novels lost both.
      final chapters = parseDirectory(payload()).expand((v) => v).toList();
      expect(chapters.map((c) => c.volumeName), ['第一卷：默认', '第一卷：默认']);
    });

    test('a chapter without a version still parses', () {
      final chapters = parseDirectory({
        'data': {
          'item_data_list': [
            {'item_id': 'c1', 'title': '第1章'},
          ],
        },
      }).expand((v) => v).toList();
      expect(chapters.single.version, '');
      expect(chapters.single.itemId, 'c1');
    });

    test('bridge chapters get the version from the raw list beside them', () {
      // Live shape of /api/directory: the bridge's normalized
      // chapterListWithVolume entries carry no version, and the raw
      // item_data_list with versions sits one level up in the same payload.
      // Reading only the normalized shape left every Chapter.version empty,
      // which the paragraph-comment sheet surfaced as 评论加载失败.
      final payload = {
        'code': 0,
        'data': {
          'item_data_list': [
            {
              'item_id': 'c1',
              'title': '第1章',
              'volume_name': '第一卷：默认',
              'version': 'abc_1_def',
            },
          ],
          'data': {
            'chapterListWithVolume': [
              [
                {
                  'itemId': 'c1',
                  'title': '第1章',
                  'volume_name': '第一卷：默认',
                },
              ],
            ],
          },
        },
      };
      final chapters = parseDirectory(payload).expand((v) => v).toList();
      expect(chapters.map((c) => c.itemId), ['c1']);
      expect(chapters.single.version, 'abc_1_def');
      expect(chapters.single.volumeName, '第一卷：默认');
    });

    test('drama episodes keep their numbered volume', () {
      final chapters = parseDirectory({
        'data': {
          'episodes': [
            {'item_id': 'e1', 'title': '第1集'},
          ],
        },
      }).expand((v) => v).toList();
      expect(chapters.single.volumeName, '剧集');
    });

    test('the version survives a cache round trip', () {
      final chapters = parseDirectory(payload()).expand((v) => v).toList();
      final restored = CachedBook.fromMap(
        jsonDecode(
          jsonEncode(
            CachedBook(
              id: 'book',
              title: 't',
              cover: '',
              chapters: chapters,
            ).toMap(),
          ),
        ),
      );
      expect(restored, isNotNull);
      expect(restored!.chapters.map((c) => c.version), [
        'abc_1_def',
        'ghi_1_jkl',
      ]);
    });

    test('a cache written before the version was kept restores empty', () {
      final restored = CachedBook.fromMap({
        'id': 'book',
        'title': 't',
        'chapters': [
          {'itemId': 'c1', 'title': '第1章', 'volumeName': '正文'},
        ],
      });
      expect(restored, isNotNull);
      expect(restored!.chapters.single.version, '');
      expect(restored.chapters.single.itemId, 'c1');
    });
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
    final item = tabs.singleWhere((tab) => tab.title == '短剧').items.single;
    expect(item.id, 's1');
    expect(item.seriesId, 's1');
    expect(item.kind, 'video');
    expect(item.title, '初次沦陷');
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

  test('recognizes genre 4 audio books without an audio label or ID field', () {
    for (final genre in [4, '4']) {
      final raw = {
        'book_id': '7239243941252598845',
        'book_name': '全球冰封：我打造了末日安全屋',
        'category': '科幻末世',
        'genre': genre,
        'genre_type': '1',
        'book_type': '1',
        'is_ebook': '0',
      };
      for (final item in [
        MediaItem.fromRaw(raw),
        MediaItem.fromRaw({'book_data': raw}),
      ]) {
        expect(item.kind, 'audio');
        expect(item.id, '7239243941252598845');
        expect(item.title, '全球冰封：我打造了末日安全屋');
      }
    }
  });

  test(
    'parses the real manga genre pair in raw and wrapped search results',
    () {
      for (final codes in [
        [1, 110],
        ['1', '110'],
      ]) {
        final raw = {
          'code': 0,
          'search_tabs': [
            {
              'title': '漫画',
              'tab_type': 8,
              'data': [
                {
                  'book_data': [
                    {
                      'book_id': '7113804239352105991',
                      'book_name': '我在精神病院学斩神',
                      'category': '都市脑洞',
                      'genre': codes[0],
                      'genre_type': codes[1],
                      'is_ebook': '1',
                    },
                  ],
                },
              ],
            },
          ],
        };
        for (final payload in [
          raw,
          {'code': 200, 'data': raw},
        ]) {
          final tab = parseSearchTabs(payload).single;
          expect(tab.title, '漫画');
          expect(tab.items.single.kind, 'manga');
          expect(tab.items.single.id, '7113804239352105991');
          expect(tab.items.single.title, '我在精神病院学斩神');
        }
      }
    },
  );

  test('publication genres and comic-themed novel titles stay books', () {
    for (final raw in [
      {
        'book_id': '7050043210055289869',
        'book_name': '最后一个道士（全七册）',
        'category': '悬疑脑洞',
        'genre': '6',
        'genre_type': '160',
      },
      {
        'book_id': '7657916022938143768',
        'book_name': '身为漫画路人的我也要拯救世界吗',
        'category': '现言脑洞',
        'genre': '0',
        'genre_type': '0',
      },
      {
        'book_id': '6993297551990459399',
        // Some publications contain image chapters, but these search fields
        // alone do not distinguish them from prose publications.
        'book_name': '罗小黑战记1（同名动画原著）',
        'category': '国内影视',
        'genre': '6',
        'genre_type': '160',
      },
    ]) {
      final tab = parseSearchTabs({
        'data': {
          'search_tabs': [
            {
              // The backend fills empty tabs with unfiltered general hits.
              'title': '漫画',
              'tab_type': 8,
              'data': [
                {'book_data': raw},
              ],
            },
          ],
        },
      }).single;
      expect(tab.items.single.kind, 'book');
      expect(tab.items.single.id, raw['book_id']);
    }
  });

  test('numeric media genres preserve explicit kinds and video identities', () {
    final saved = MediaItem.fromRaw({
      'book_id': 'saved-book',
      'kind': 'book',
      'genre': '4',
      'genre_type': '1',
    });
    expect(saved.kind, 'book');
    final video = MediaItem.fromRaw({
      'video_id': 'video-1',
      'genre': '1',
      'genre_type': '110',
    });
    expect(video.kind, 'video');
    expect(video.id, 'video-1');
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

  test('item JSON round-trip keeps the promotional tag', () {
    final item = MediaItem(
      id: 'b2',
      title: '标签小说',
      cover: 'https://example.test/cover.jpg',
      author: '作者',
      badge: '',
      ep: '',
      kind: 'book',
      tag: MediaTag(
        text: '上新',
        lightColors: ['#FF5500'],
        darkColors: ['#FF7A33'],
      ),
      seriesId: 's1',
      episodeId: 'e1',
    );
    final restored = MediaItemJson.fromJson(item.toJson());
    expect(restored, isNotNull);
    expect(restored!.id, item.id);
    expect(restored.title, item.title);
    expect(restored.kind, item.kind);
    expect(restored.seriesId, 's1');
    expect(restored.episodeId, 'e1');
    expect(restored.tag, isNotNull);
    expect(restored.tag!.text, '上新');
    expect(restored.tag!.colorsFor(dark: true), ['#FF7A33']);
    // Required-field integrity: a truncated map cannot resurrect an item.
    expect(MediaItemJson.fromJson({'id': 'b3'}), isNull);
  });

  test('video_detail info-panel fields reach the flat card', () {
    // 真实 `cell/change` 卡形状（show_type=407）：信息面板数据在
    // video_detail（简介/追剧数/分类），style 骑在模板 cell 上。
    final payload = {
      'data': {
        'cell_view': {
          'cell_data': [
            {
              'show_type': 407,
              'style': {'episode_list_text': '观看完整漫剧·全153集'},
              'video_data': [
                {
                  'vid': 'v1',
                  'series_id_str': '7680187265020070937',
                  'video_detail': {
                    'series_title': '反派亲妈',
                    'series_intro': '穿成反派亲妈？',
                    'followed_cnt': 687558,
                    'episode_cnt': 153,
                    'secondary_infos': [
                      {
                        'can_click': true,
                        'content': '都市日常',
                        'data_type': 3,
                      },
                      {
                        'can_click': true,
                        'content': '演员·萨钢云',
                        'data_type': 23,
                      },
                    ],
                  },
                },
              ],
            },
          ],
        },
      },
    };

    final items = parseMediaItems(payload, kind: 'manju');
    expect(items, hasLength(1));
    final item = items.single;
    expect(item.intro, '穿成反派亲妈？');
    expect(item.followerCount, 687558);
    // 只有 data_type=3 的 secondary_infos 是分类；演员条目不进 chip 行。
    expect(item.categories, ['都市日常']);
    expect(item.episodeListText, '观看完整漫剧·全153集');
    expect(item.ep, '153');
  });

  test('category chips fall back to category_schema names', () {
    final payload = {
      'data': {
        'video_data': [
          {
            'vid': 'v2',
            'series_id_str': '1001',
            'series_title': '无 secondary 的卡',
            'category_schema': '[{"category_id":748,"name":"喜剧"}]',
          },
        ],
      },
    };

    final items = parseMediaItems(payload, kind: 'video');
    expect(items, hasLength(1));
    expect(items.single.categories, ['喜剧']);
    expect(items.single.followerCount, 0);
  });
}
