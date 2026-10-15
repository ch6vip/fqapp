import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/imported_book_store.dart';
import 'package:image/image.dart' as img;

void main() {
  group('parseImportedBookBytes', () {
    test('按常见中文章节标题切分 TXT 并保留章节正文', () {
      final parsed = parseImportedBookBytes(
        fileName: '故事.txt',
        bytes: Uint8List.fromList(
          utf8.encode('第一章 开始\n清晨醒来。\n\n第二章 出发\n走向远方。'),
        ),
      );

      expect(parsed.title, '故事');
      expect(parsed.format, 'txt');
      expect(parsed.chapters.map((chapter) => chapter.title), [
        '第一章 开始',
        '第二章 出发',
      ]);
      expect(parsed.chapters.first.text, contains('清晨醒来'));
      expect(parsed.chapters.last.text, contains('走向远方'));
    });

    test('跳过只有标题没有正文的章节，如文件开头的目录页', () {
      final parsed = parseImportedBookBytes(
        fileName: '故事.txt',
        bytes: Uint8List.fromList(
          utf8.encode(
            '第一章 开始\n第二章 出发\n第一章 开始\n清晨醒来。\n第二章 出发\n走向远方。',
          ),
        ),
      );

      // 开头的两条目录条目只有标题、没有正文，丢弃后只剩带正文的真章节，
      // 否则阅读器打开它们会报“正文为空”。
      expect(parsed.chapters.map((chapter) => chapter.title), [
        '第一章 开始',
        '第二章 出发',
      ]);
      expect(parsed.chapters.first.text, contains('清晨醒来'));
      expect(parsed.chapters.last.text, contains('走向远方'));
    });

    test('没有章节标题时把 TXT 作为单章导入', () {
      final parsed = parseImportedBookBytes(
        fileName: '散文.TXT',
        bytes: Uint8List.fromList(utf8.encode('第一段\n\n第二段')),
      );

      expect(parsed.title, '散文');
      expect(parsed.chapters, hasLength(1));
      expect(parsed.chapters.single.text, contains('第二段'));
    });

    test('按 EPUB spine 顺序提取章节标题、作者与正文', () {
      final archive = Archive()
        ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
        ..addFile(
          ArchiveFile.string(
            'META-INF/container.xml',
            '''<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
</container>''',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OEBPS/content.opf',
            '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <metadata><dc:title>EPUB 书名</dc:title><dc:creator>作者甲</dc:creator></metadata>
  <manifest><item id="one" href="Text/one.xhtml" media-type="application/xhtml+xml"/>
    <item id="two" href="Text/two.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="two"/><itemref idref="one"/></spine>
</package>''',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OEBPS/Text/one.xhtml',
            '<html><body><h1>第一章</h1><p>正文一。</p></body></html>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OEBPS/Text/two.xhtml',
            '<html><body><h1>序章</h1><p>正文二。</p></body></html>',
          ),
        );
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final parsed = parseImportedBookBytes(fileName: 'fallback.epub', bytes: bytes);

      expect(parsed.title, 'EPUB 书名');
      expect(parsed.author, '作者甲');
      expect(parsed.chapters.map((chapter) => chapter.title), ['序章', '第一章']);
      expect(parsed.chapters.first.text, contains('正文二'));
    });

    test('跳过 EPUB spine 里只有标题的 nav 目录文档', () {
      final archive = Archive()
        ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
        ..addFile(
          ArchiveFile.string(
            'META-INF/container.xml',
            '''<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
</container>''',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OEBPS/content.opf',
            '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <metadata><dc:title>EPUB 书名</dc:title></metadata>
  <manifest><item id="nav" href="Text/nav.xhtml" media-type="application/xhtml+xml"/>
    <item id="one" href="Text/one.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="nav"/><itemref idref="one"/></spine>
</package>''',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OEBPS/Text/nav.xhtml',
            '<html><body><h1>目录</h1><nav><ol><li><a href="one.xhtml">第一章</a></li></ol></nav></body></html>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'OEBPS/Text/one.xhtml',
            '<html><body><h1>第一章</h1><p>正文一。</p></body></html>',
          ),
        );
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final parsed = parseImportedBookBytes(fileName: 'nav.epub', bytes: bytes);

      expect(parsed.chapters.map((chapter) => chapter.title), ['第一章']);
      expect(parsed.chapters.single.text, contains('正文一'));
    });

    test('拒绝不支持的格式与空正文', () {
      expect(
        () => parseImportedBookBytes(
          fileName: 'book.pdf',
          bytes: Uint8List.fromList([1]),
        ),
        throwsFormatException,
      );
      expect(
        () => parseImportedBookBytes(
          fileName: 'empty.txt',
          bytes: Uint8List.fromList(utf8.encode('  ')),
        ),
        throwsFormatException,
      );
      expect(
        () => parseImportedBookBytes(
          fileName: '只有标题.txt',
          bytes: Uint8List.fromList(utf8.encode('第一章 开始')),
        ),
        throwsFormatException,
      );
    });
  });

  group('ImportedBookStore', () {
    late Directory directory;
    late ImportedBookStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('fqapp-import-test-');
      store = ImportedBookStore(rootDirectoryProvider: () async => directory);
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('写入私有章节文件后仍可恢复书籍目录与正文', () async {
      final imported = await store.importBytes(
        fileName: '持久化.txt',
        bytes: Uint8List.fromList(utf8.encode('第一章\n保存在本地。')),
      );

      final loaded = await store.book(imported.id);
      expect(loaded?.title, '持久化');
      expect(loaded?.chapters, hasLength(1));
      expect(
        await store.chapterText(imported.id, imported.chapters.single.itemId),
        contains('保存在本地'),
      );
      expect((await store.books()).map((book) => book.id), [imported.id]);
    });
  });

  group('EPUB 封面发现顺序', () {
    test('优先取 EPUB3 manifest 的 cover-image 属性', () {
      final parsed = parseImportedBookBytes(
        fileName: 'a.epub',
        bytes: _epub(
          manifest:
              '<item id="art" href="Images/art.png" '
              'media-type="image/png"/>'
              '<item id="mark" href="Images/mark.png" media-type="image/png" '
              'properties="cover-image"/>',
          resources: {
            'OEBPS/Images/art.png': _coverPng(transparency: false),
            'OEBPS/Images/mark.png': _coverPng(transparency: true),
          },
        ),
      );

      // 被声明的那张才带透明像素，所以存成 PNG 才能说明选对了.
      expect(parsed.cover?.extension, 'png');
    });

    test('认 EPUB3 带 refines 的封面声明，而不是靠名字猜', () {
      final parsed = parseImportedBookBytes(
        fileName: 'b.epub',
        bytes: _epub(
          metadata: '<meta property="cover-image" refines="#art"/>',
          manifest:
              '<item id="cover-note" href="Images/cover-note.png" '
              'media-type="image/png"/>'
              '<item id="art" href="Images/art.png" media-type="image/png"/>',
          resources: {
            'OEBPS/Images/cover-note.png': _coverPng(transparency: false),
            'OEBPS/Images/art.png': _coverPng(transparency: true),
          },
        ),
      );

      expect(parsed.cover?.extension, 'png');
    });

    test('认 EPUB2 的 meta name=cover 指向的清单 id', () {
      final parsed = parseImportedBookBytes(
        fileName: 'c.epub',
        bytes: _epub(
          metadata: '<meta name="cover" content="art"/>',
          manifest:
              '<item id="cover-note" href="Images/cover-note.png" '
              'media-type="image/png"/>'
              '<item id="art" href="Images/art.png" media-type="image/png"/>',
          resources: {
            'OEBPS/Images/cover-note.png': _coverPng(transparency: false),
            'OEBPS/Images/art.png': _coverPng(transparency: true),
          },
        ),
      );

      expect(parsed.cover?.extension, 'png');
    });

    test('兼容 meta name=cover 里直接写相对路径的坏包', () {
      final parsed = parseImportedBookBytes(
        fileName: 'd.epub',
        bytes: _epub(
          metadata: '<meta name="cover" content="Images/art.png"/>',
          manifest:
              '<item id="art" href="Images/art.png" media-type="image/png"/>',
          resources: {
            'OEBPS/Images/art.png': _coverPng(transparency: true),
          },
        ),
      );

      expect(parsed.cover?.extension, 'png');
    });

    test('认 guide 里的封面文档并跟一层内部引用', () {
      final parsed = parseImportedBookBytes(
        fileName: 'e.epub',
        bytes: _epub(
          manifest:
              '<item id="titlepage" href="Text/titlepage.xhtml" '
              'media-type="application/xhtml+xml"/>',
          guide:
              '<guide><reference type="cover" '
              'href="Text/titlepage.xhtml"/></guide>',
          resources: {
            'OEBPS/Text/titlepage.xhtml': utf8.encode(
              '<html><body><img src="../Images/art.png"/></body></html>',
            ),
            'OEBPS/Images/art.png': _coverPng(transparency: true),
          },
        ),
      );

      expect(parsed.cover?.extension, 'png');
    });

    test('没有任何声明时只认带 cover 提示的资源，绝不取第一张图', () {
      final parsed = parseImportedBookBytes(
        fileName: 'f.epub',
        bytes: _epub(
          manifest:
              '<item id="plate" href="Images/plate.png" '
              'media-type="image/png"/>'
              '<item id="front" href="Images/front-cover.png" '
              'media-type="image/png"/>',
          resources: {
            'OEBPS/Images/plate.png': _coverPng(transparency: false),
            'OEBPS/Images/front-cover.png': _coverPng(transparency: true),
          },
        ),
      );

      expect(parsed.cover?.extension, 'png');
    });

    test('提示不命中时不给封面，不拿第一张图顶替', () {
      final parsed = parseImportedBookBytes(
        fileName: 'g.epub',
        bytes: _epub(
          manifest:
              '<item id="plate" href="Images/plate.png" '
              'media-type="image/png"/>',
          resources: {
            'OEBPS/Images/plate.png': _coverPng(transparency: false),
          },
        ),
      );

      expect(parsed.cover, isNull);
    });

    test('外部 URL 与非图片载荷都被拒绝', () {
      final externalUrl = parseImportedBookBytes(
        fileName: 'h.epub',
        bytes: _epub(
          metadata:
              '<meta name="cover" content="http://example.invalid/c.png"/>',
          manifest: '',
        ),
      );
      expect(externalUrl.cover, isNull);

      final notAnImage = parseImportedBookBytes(
        fileName: 'i.epub',
        bytes: _epub(
          metadata: '<meta name="cover" content="notes"/>',
          manifest:
              '<item id="notes" href="Text/notes.txt" '
              'media-type="text/plain"/>',
          resources: {
            'OEBPS/Text/notes.txt': utf8.encode('这里不是图片'),
          },
        ),
      );
      expect(notAnImage.cover, isNull);
    });

    test('SVG 封面原样保留，外部引用不会被当成封面', () {
      final plain = parseImportedBookBytes(
        fileName: 'j.epub',
        bytes: _epub(
          metadata: '<meta name="cover" content="art"/>',
          manifest:
              '<item id="art" href="Images/art.svg" '
              'media-type="image/svg+xml"/>',
          resources: {
            'OEBPS/Images/art.svg': utf8.encode(
              '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">'
              '<rect width="8" height="8" fill="#123456"/></svg>',
            ),
          },
        ),
      );
      expect(plain.cover?.extension, 'svg');

      final externalRef = parseImportedBookBytes(
        fileName: 'k.epub',
        bytes: _epub(
          metadata: '<meta name="cover" content="art"/>',
          manifest:
              '<item id="art" href="Images/art.svg" '
              'media-type="image/svg+xml"/>',
          resources: {
            'OEBPS/Images/art.svg': utf8.encode(
              '<svg xmlns="http://www.w3.org/2000/svg">'
              '<image href="https://example.invalid/x.png"/></svg>',
            ),
          },
        ),
      );
      expect(externalRef.cover?.extension, 'svg');
    });
  });

  group('ImportedBookStore 封面落盘', () {
    late Directory directory;
    late ImportedBookStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('fqapp-cover-test-');
      store = ImportedBookStore(rootDirectoryProvider: () async => directory);
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('封面随书落盘并写进书架条目', () async {
      final imported = await store.importBytes(
        fileName: '带封面.epub',
        bytes: _epub(
          manifest:
              '<item id="art" href="Images/art.png" '
              'media-type="image/png" properties="cover-image"/>',
          resources: {
            'OEBPS/Images/art.png': _coverPng(transparency: true),
          },
        ),
      );

      expect(imported.coverFile, 'cover.png');
      final coverPath = imported.coverPath;
      expect(coverPath, isNotNull);
      expect(await File(coverPath!).exists(), isTrue);
      expect(imported.toMediaItem().cover, coverPath);

      final loaded = await store.book(imported.id);
      expect(loaded?.coverFile, 'cover.png');
      expect(loaded?.toMediaItem().cover, coverPath);
    });

    test('没有封面的 TXT 保持空 cover，交给默认封面', () async {
      final imported = await store.importBytes(
        fileName: '无封面.txt',
        bytes: Uint8List.fromList(utf8.encode('第一章\n正文。')),
      );

      expect(imported.coverFile, isNull);
      expect(imported.toMediaItem().cover, isEmpty);
      expect((await store.book(imported.id))?.toMediaItem().cover, isEmpty);
    });

    test('清单里的越界封面名被丢弃', () async {
      final imported = await store.importBytes(
        fileName: '防篡改.txt',
        bytes: Uint8List.fromList(utf8.encode('第一章\n正文。')),
      );
      final manifest = File(
        '${imported.directory}${Platform.pathSeparator}book.json',
      );
      final raw =
          jsonDecode(await manifest.readAsString(encoding: utf8))
              as Map<String, dynamic>;
      raw['cover'] = '../../etc/passwd';
      await manifest.writeAsString(jsonEncode(raw), encoding: utf8);

      expect((await store.book(imported.id))?.coverFile, isNull);
    });
  });
}

/// A tiny cover image. [transparency] decides which side of the PNG/JPEG split
/// the stored cover lands on.
Uint8List _coverPng({required bool transparency}) {
  final image = img.Image(width: 8, height: 8, numChannels: 4);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final alpha = transparency && x == 0 && y == 0 ? 0 : 255;
      image.setPixelRgba(x, y, 10, 20, 30, alpha);
    }
  }
  return img.encodePng(image);
}

/// Builds a minimal EPUB whose OPF pieces and cover resources come from the
/// caller, so every discovery rule can be exercised on its own.
Uint8List _epub({
  required String manifest,
  String metadata = '',
  String guide = '',
  Map<String, List<int>> resources = const {},
}) {
  const opfPath = 'OEBPS/content.opf';
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<?xml version="1.0"?>'
            '<container '
            'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="$opfPath"/></rootfiles>'
            '</container>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        opfPath,
        '<?xml version="1.0"?>'
            '<package xmlns="http://www.idpf.org/2007/opf" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<metadata><dc:title>封面书</dc:title>'
            '<dc:creator>测试作者</dc:creator>$metadata</metadata>'
            '<manifest>$manifest'
            '<item id="c1" href="Text/c1.xhtml" '
            'media-type="application/xhtml+xml"/></manifest>'
            '<spine><itemref idref="c1"/></spine>$guide'
            '</package>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/Text/c1.xhtml',
        '<html><body><h1>第一章</h1><p>正文。</p></body></html>',
      ),
    );
  for (final resource in resources.entries) {
    archive.addFile(
      ArchiveFile.bytes(resource.key, Uint8List.fromList(resource.value)),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
