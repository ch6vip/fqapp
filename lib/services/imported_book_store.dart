import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import '../models/media_item.dart';

const _maxBookFileBytes = 32 * 1024 * 1024;
const _maxExpandedEpubBytes = 64 * 1024 * 1024;
const _maxEpubEntries = 4000;
const _maxImportedChapters = 20000;
const _bookIdPattern = r'^local_[0-9]+_[a-f0-9]+$';

// Cover storage mirrors Legado: the artwork is read with a byte cap, sniffed by
// magic number instead of trusting the declared media type, shrunk to
// [_maxCoverImageEdge] and re-encoded — PNG while transparency survives, JPEG
// otherwise.  SVG artwork stays verbatim and is drawn by flutter_svg.
const _maxCoverResourceBytes = 8 * 1024 * 1024;
const _maxCoverDocumentBytes = 1024 * 1024;
const _maxCoverImageEdge = 1600;
const _maxCoverAlphaScanPixels = 512 * 1000;
const _coverJpegQuality = 90;
const _coverFilePattern = r'^cover\.(?:png|jpg|svg)$';
const _coverHint =
    r'(?:^|[/_.~\-])(cover|frontcover|titlepage|title-page)(?:$|[/_.~\-])';

final _coverHintPattern = RegExp(_coverHint, caseSensitive: false);

/// An imported book and its ordered local chapter catalogue.
///
/// [directory] is the book's own private folder and [coverFile] the cover
/// stored inside it, or null when the source document carried none.  The
/// absolute path handed to the shelf is derived from the two, which is how
/// Legado keeps an extracted cover next to the book it belongs to.
class ImportedBook {
  final String id;
  final String title;
  final String author;
  final String format;
  final DateTime addedAt;
  final List<Chapter> chapters;
  final String directory;
  final String? coverFile;
  final List<String> _chapterFiles;

  ImportedBook._({
    required this.id,
    required this.title,
    required this.author,
    required this.format,
    required this.addedAt,
    required this.directory,
    required this.coverFile,
    required List<Chapter> chapters,
    required List<String> chapterFiles,
  }) : chapters = List.unmodifiable(chapters),
       _chapterFiles = List.unmodifiable(chapterFiles);

  /// Absolute path of the stored cover, or null when the book has none.
  ///
  /// The shelf renders it as a local file; a path that no longer resolves (data
  /// cleared, app reinstalled) falls back to the default cover at draw time.
  String? get coverPath {
    final file = coverFile;
    if (file == null) return null;
    return '$directory${Platform.pathSeparator}$file';
  }

  /// The shelf entry for this book. A book without artwork keeps an empty
  /// cover so the shelf paints its own default cover instead of a broken image.
  MediaItem toMediaItem() => MediaItem(
    id: id,
    title: title,
    cover: coverPath ?? '',
    author: author,
    badge: '本地',
    ep: chapters.length.toString(),
    kind: 'book',
  );

  Map<String, dynamic> _toManifest() => {
    'id': id,
    'title': title,
    'author': author,
    'format': format,
    'addedAt': addedAt.millisecondsSinceEpoch,
    'cover': coverFile,
    'chapters': [
      for (var index = 0; index < chapters.length; index++)
        {
          'id': chapters[index].itemId,
          'title': chapters[index].title,
          'file': _chapterFiles[index],
        },
    ],
  };
}

/// One parsed chapter before it is stored in the app-private directory.
@immutable
class ParsedBookChapter {
  final String title;
  final String text;
  const ParsedBookChapter({required this.title, required this.text});
}

/// Cover artwork decoded from the source document, in the shape it is stored
/// in: raster artwork is re-encoded (PNG while transparency survives, JPEG
/// otherwise) and SVG is kept verbatim for flutter_svg.
@immutable
class ParsedBookCover {
  final Uint8List bytes;
  final String extension;
  const ParsedBookCover({required this.bytes, required this.extension});
}

/// Parsed book data, independent of Flutter and filesystem state.
@immutable
class ParsedImportedBook {
  final String title;
  final String author;
  final String format;
  final ParsedBookCover? cover;
  final List<ParsedBookChapter> chapters;

  ParsedImportedBook({
    required this.title,
    required this.author,
    required this.format,
    required List<ParsedBookChapter> chapters,
    this.cover,
  }) : chapters = List.unmodifiable(chapters);
}

/// Local imported-book persistence. Book text is stored as private chapter
/// files; the source document is not retained and is never uploaded.
class ImportedBookStore {
  ImportedBookStore({Future<Directory> Function()? rootDirectoryProvider})
    : _rootDirectoryProvider =
          rootDirectoryProvider ?? getApplicationSupportDirectory;

  static final ImportedBookStore instance = ImportedBookStore();
  static const _picker = MethodChannel('fqapp/local_books');
  static bool isLocalBookId(String id) => RegExp(_bookIdPattern).hasMatch(id);

  final Future<Directory> Function() _rootDirectoryProvider;
  Future<Directory>? _rootFuture;
  static final _random = Random.secure();

  Future<Directory> _root() => _rootFuture ??= _createRoot();

  Future<ImportedBook?> pickAndImport() async {
    final selected = await _picker.invokeMapMethod<Object?, Object?>(
      'pickBookFile',
    );
    if (selected == null) return null;
    final fileName = selected['name']?.toString() ?? '';
    final decodedText = selected['text'] is String
        ? selected['text'] as String
        : null;
    final sourceByteLength = selected['byteLength'] is int
        ? selected['byteLength'] as int
        : null;
    final rawBytes = selected['bytes'];
    final bytes = rawBytes is Uint8List
        ? rawBytes
        : rawBytes is List<int>
        ? Uint8List.fromList(rawBytes)
        : null;
    final isTxt = fileName.toLowerCase().endsWith('.txt');
    if (fileName.isEmpty ||
        (isTxt && (decodedText == null || sourceByteLength == null)) ||
        (!isTxt && bytes == null)) {
      throw const FormatException('无法读取所选文件');
    }
    return importBytes(
      fileName: fileName,
      bytes: bytes ?? Uint8List(0),
      decodedText: decodedText,
      sourceByteLength: sourceByteLength,
    );
  }

  Future<Directory> _createRoot() async {
    final support = await _rootDirectoryProvider();
    final root = Directory(
      '${support.path}${Platform.pathSeparator}imported_books',
    );
    await root.create(recursive: true);
    return root;
  }

  /// Parses a chosen TXT or EPUB in a worker isolate and persists its chapters.
  Future<ImportedBook> importBytes({
    required String fileName,
    required Uint8List bytes,
    String? decodedText,
    int? sourceByteLength,
  }) async {
    if (bytes.isEmpty && decodedText == null) {
      throw const FormatException('文件内容为空');
    }
    final byteLength = sourceByteLength ?? bytes.lengthInBytes;
    if (byteLength < 0) throw const FormatException('文件长度无效');
    if (byteLength > _maxBookFileBytes) {
      throw const FormatException('请选择小于 32 MB 的 TXT 或 EPUB 文件');
    }
    final parsedData = await Isolate.run<Map<String, Object?>>(() {
      final parsed = parseImportedBookBytes(
        fileName: fileName,
        bytes: bytes,
        decodedText: decodedText,
      );
      return {
        'title': parsed.title,
        'author': parsed.author,
        'format': parsed.format,
        'coverBytes': parsed.cover?.bytes,
        'coverExtension': parsed.cover?.extension,
        'chapters': [
          for (final chapter in parsed.chapters)
            {'title': chapter.title, 'text': chapter.text},
        ],
      };
    });
    final coverBytes = parsedData['coverBytes'];
    final parsed = ParsedImportedBook(
      title: parsedData['title']! as String,
      author: parsedData['author']! as String,
      format: parsedData['format']! as String,
      cover: coverBytes is Uint8List
          ? ParsedBookCover(
              bytes: coverBytes,
              extension: parsedData['coverExtension']! as String,
            )
          : null,
      chapters: [
        for (final chapter in parsedData['chapters']! as List)
          ParsedBookChapter(
            title: (chapter as Map)['title']! as String,
            text: chapter['text']! as String,
          ),
      ],
    );
    final root = await _root();
    final id = _newId();
    final staging = Directory('${root.path}${Platform.pathSeparator}.$id.tmp');
    final target = Directory('${root.path}${Platform.pathSeparator}$id');
    await staging.create();
    try {
      final chapters = <Chapter>[];
      final files = <String>[];
      for (var index = 0; index < parsed.chapters.length; index++) {
        final source = parsed.chapters[index];
        final name = 'chapter_${index.toString().padLeft(5, '0')}.txt';
        final file = File('${staging.path}${Platform.pathSeparator}$name');
        await file.writeAsString(source.text, encoding: utf8, flush: true);
        files.add(name);
        chapters.add(
          Chapter(
            itemId: '$id:chapter:$index',
            title: source.title,
            volumeName: '',
          ),
        );
      }
      String? coverFile;
      final cover = parsed.cover;
      if (cover != null) {
        final name = 'cover.${cover.extension}';
        await File(
          '${staging.path}${Platform.pathSeparator}$name',
        ).writeAsBytes(cover.bytes, flush: true);
        coverFile = name;
      }
      final book = ImportedBook._(
        id: id,
        title: parsed.title,
        author: parsed.author,
        format: parsed.format,
        addedAt: DateTime.now(),
        directory: target.path,
        coverFile: coverFile,
        chapters: chapters,
        chapterFiles: files,
      );
      await File(
        '${staging.path}${Platform.pathSeparator}book.json',
      ).writeAsString(
        jsonEncode(book._toManifest()),
        encoding: utf8,
        flush: true,
      );
      await staging.rename(target.path);
      return book;
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<ImportedBook?> book(String id) async {
    if (!RegExp(_bookIdPattern).hasMatch(id)) return null;
    final root = await _root();
    final manifest = File(
      '${root.path}${Platform.pathSeparator}$id${Platform.pathSeparator}book.json',
    );
    if (!await manifest.exists()) return null;
    try {
      final raw = jsonDecode(await manifest.readAsString(encoding: utf8));
      if (raw is! Map) return null;
      return _fromManifest(
        raw,
        expectedId: id,
        directory: '${root.path}${Platform.pathSeparator}$id',
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<ImportedBook>> books() async {
    final root = await _root();
    final books = <ImportedBook>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = entity.path.replaceAll('\\', '/').split('/').last;
      if (!RegExp(_bookIdPattern).hasMatch(id)) continue;
      final book = await this.book(id);
      if (book != null) books.add(book);
    }
    books.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return books;
  }

  /// Deletes one imported book and its private directory.
  ///
  /// Called when a locally imported book leaves the shelf: the chapters and the
  /// extracted cover live only in that folder, so leaving it behind would leak
  /// the whole text with no way to reach it again. A wrong-shaped id is refused
  /// rather than resolved, so this can never walk out of the book root.
  Future<bool> deleteBook(String id) async {
    if (!isLocalBookId(id)) return false;
    final root = await _root();
    final directory = Directory('${root.path}${Platform.pathSeparator}$id');
    if (!await directory.exists()) return false;
    await directory.delete(recursive: true);
    return true;
  }

  Future<String> chapterText(String bookId, String chapterId) async {
    final record = await book(bookId);
    if (record == null) throw const FileSystemException('找不到本地书籍');
    final index = record.chapters.indexWhere(
      (chapter) => chapter.itemId == chapterId,
    );
    if (index < 0) throw const FileSystemException('找不到本地章节');
    final root = await _root();
    final file = File(
      [
        root.path,
        bookId,
        record._chapterFiles[index],
      ].join(Platform.pathSeparator),
    );
    return file.readAsString(encoding: utf8);
  }

  String _newId() {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final salt = _random.nextInt(1 << 32).toRadixString(16);
    return 'local_${timestamp}_$salt';
  }

  ImportedBook? _fromManifest(
    Map raw, {
    required String expectedId,
    required String directory,
  }) {
    if (raw['id'] != expectedId || raw['chapters'] is! List) return null;
    final title = raw['title']?.toString().trim() ?? '';
    if (title.isEmpty) return null;
    final chapters = <Chapter>[];
    final files = <String>[];
    for (final value in raw['chapters'] as List) {
      if (value is! Map) continue;
      final id = value['id']?.toString() ?? '';
      final file = value['file']?.toString() ?? '';
      if (id.isEmpty ||
          !file.startsWith('chapter_') ||
          !file.endsWith('.txt') ||
          file.contains('/') ||
          file.contains('\\')) {
        continue;
      }
      chapters.add(
        Chapter(
          itemId: id,
          title: value['title']?.toString() ?? '第${chapters.length + 1}章',
          volumeName: '',
        ),
      );
      files.add(file);
    }
    if (chapters.isEmpty || chapters.length != files.length) return null;
    final addedAt = raw['addedAt'];
    // The cover name is validated like the chapter files: it must be one of the
    // names this store writes and must not contain a path separator. A stored
    // value that no longer matches is dropped rather than trusted, so a
    // tampered manifest can never point the shelf at an arbitrary file.
    final rawCover = raw['cover']?.toString() ?? '';
    final coverFile = RegExp(_coverFilePattern).hasMatch(rawCover)
        ? rawCover
        : null;
    return ImportedBook._(
      id: expectedId,
      title: title,
      author: raw['author']?.toString() ?? '',
      format: raw['format']?.toString() ?? '',
      addedAt: DateTime.fromMillisecondsSinceEpoch(
        addedAt is num ? addedAt.toInt() : 0,
      ),
      directory: directory,
      coverFile: coverFile,
      chapters: chapters,
      chapterFiles: files,
    );
  }
}

/// Parses a local document synchronously. Production calls this through
/// [Isolate.run]; keeping the pure parser public makes its format handling
/// directly testable without a platform picker.
ParsedImportedBook parseImportedBookBytes({
  required String fileName,
  required Uint8List bytes,
  String? decodedText,
}) {
  final extension = fileName.toLowerCase().split('.').last;
  final title = _fileTitle(fileName);
  if (extension == 'txt') {
    final text = decodedText ?? _decodeText(bytes);
    return _parseTxt(title, text);
  }
  if (extension == 'epub') return _parseEpub(title, bytes);
  throw const FormatException('仅支持 TXT 和 EPUB 文件');
}

ParsedImportedBook _parseTxt(String fileTitle, String source) {
  final normalized = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u0000', '')
      .replaceAll('\f', '\n\n')
      .trim();
  if (normalized.isEmpty) throw const FormatException('TXT 正文为空');
  final lines = normalized.split('\n');
  final headingPattern = RegExp(
    r'^\s*(?:第[0-9０-９零〇一二三四五六七八九十百千万两]+[章节回卷部集篇].*|'
    r'[0-9]{1,5}[.、 ]+\S.*|'
    r'卷[0-9０-９零〇一二三四五六七八九十百千万两]+.*|'
    r'序章|序言|楔子|前言|后记|尾声|番外(?:第.*)?|正文)\s*$',
  );
  final headings = <int>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line.isNotEmpty &&
        line.length <= 100 &&
        headingPattern.hasMatch(line)) {
      headings.add(index);
    }
    if (headings.length > _maxImportedChapters) {
      throw const FormatException('章节数量超过支持上限');
    }
  }

  final chapters = <ParsedBookChapter>[];
  if (headings.length > 1) {
    for (var index = 0; index < headings.length; index++) {
      final start = headings[index];
      final end = index + 1 < headings.length
          ? headings[index + 1]
          : lines.length;
      final content = lines.sublist(start, end).join('\n').trim();
      if (content.isEmpty) continue;
      final title = lines[start].trim();
      // 只有标题、没有正文的章节（如文件开头的目录页条目）会让阅读器
      // 报“正文为空”，直接丢弃，保留后面带正文的同名真章节。
      if (content == title) continue;
      chapters.add(ParsedBookChapter(title: title, text: content));
    }
  } else {
    final chapterTitle = headings.isEmpty ? '正文' : lines[headings.first].trim();
    // 整本只有标题一行时，没有可读正文，交给下面的空检查报错。
    if (normalized != chapterTitle) {
      chapters.add(ParsedBookChapter(title: chapterTitle, text: normalized));
    }
  }
  if (chapters.isEmpty) throw const FormatException('TXT 中没有可导入的正文');
  final (cleanedTitle, cleanedAuthor) = splitTitleAndAuthor(fileTitle, '');
  return ParsedImportedBook(
    title: cleanedTitle,
    author: cleanedAuthor,
    format: 'txt',
    chapters: chapters,
  );
}

/// 从原始书名与作者中智能拆分出干净的书名和作者名。
(String, String) splitTitleAndAuthor(String rawTitle, [String rawAuthor = '']) {
  var title = rawTitle.trim();
  var author = rawAuthor.trim();

  if (author.isEmpty || author == '未知作者') {
    final authorMatch = RegExp(
      r'[（(\[【]?\s*作者\s*[:：\s]+\s*([^）)\]】\s]+)[）)\]】]?',
    ).firstMatch(title);
    if (authorMatch != null) {
      author = authorMatch.group(1)?.trim() ?? '';
      title = title.replaceRange(authorMatch.start, authorMatch.end, '').trim();
    } else {
      final byMatch = RegExp(
        r'[（(\[【]?\s*by\s*[:：\s]+\s*([^）)\]】\s]+)[）)\]】]?',
        caseSensitive: false,
      ).firstMatch(title);
      if (byMatch != null) {
        author = byMatch.group(1)?.trim() ?? '';
        title = title.replaceRange(byMatch.start, byMatch.end, '').trim();
      }
    }
  }

  title = title
      .replaceAll(
        RegExp(
          r'[（(\[【]\s*(?:精校版?|校对版?|全本|全集|完结|完本|精修版?|无错版?|未删节|未删减|手打|更新|排版|精编)[^）)\]】]*[）)\]】]',
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  title = title.replaceAll(RegExp(r'^[_\-—\s,，:：]+|[_\-—\s,，:：]+$'), '').trim();
  author = author
      .replaceAll(RegExp(r'^(?:作者|by)[:：\s]*', caseSensitive: false), '')
      .trim();

  if (title.isEmpty) title = rawTitle.trim();
  return (title, author);
}

ParsedImportedBook _parseEpub(String fileTitle, Uint8List bytes) {
  _checkEpubZipLimits(bytes);
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  final containerFile = archive.findFile('META-INF/container.xml');
  if (containerFile == null) {
    throw const FormatException('EPUB 缺少 META-INF/container.xml');
  }
  final container = XmlDocument.parse(_decodeXmlBytes(containerFile.content));
  final rootfile = _firstElement(container, 'rootfile');
  final opfPath = rootfile?.getAttribute('full-path');
  if (opfPath == null || opfPath.trim().isEmpty) {
    throw const FormatException('EPUB 目录文件无效');
  }
  final normalizedOpfPath = _resolveArchiveHref('', opfPath);
  if (normalizedOpfPath.isEmpty) {
    throw const FormatException('EPUB 目录路径无效');
  }
  final opfFile = archive.findFile(normalizedOpfPath);
  if (opfFile == null) throw const FormatException('EPUB 目录文件不存在');
  final opf = XmlDocument.parse(_decodeXmlBytes(opfFile.content));
  final elements = opf.rootElement.descendants.whereType<XmlElement>().toList();
  final title = elements
      .where((element) => element.localName == 'title')
      .map((element) => element.innerText.trim())
      .firstWhere((value) => value.isNotEmpty, orElse: () => fileTitle);
  final author = elements
      .where((element) => element.localName == 'creator')
      .map((element) => element.innerText.trim())
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');
  final manifest =
      <String, ({String href, String mediaType, Set<String> properties})>{};
  for (final element in elements.where(
    (element) => element.localName == 'item',
  )) {
    final id = element.getAttribute('id');
    final href = element.getAttribute('href');
    if (id == null || href == null || id.isEmpty || href.isEmpty) continue;
    manifest[id] = (
      href: href,
      mediaType: element.getAttribute('media-type') ?? '',
      properties: _propertyTokens(element.getAttribute('properties')),
    );
  }
  final spine = elements.where((element) => element.localName == 'itemref');
  final baseDirectory = normalizedOpfPath.contains('/')
      ? normalizedOpfPath.substring(0, normalizedOpfPath.lastIndexOf('/'))
      : '';
  // Cover extraction is best effort: a damaged artwork must not fail the whole
  // import, so any failure here reads as "this book has no cover".
  final cover = _extractEpubCover(elements, manifest, baseDirectory, archive);
  final chapters = <ParsedBookChapter>[];
  for (final itemRef in spine) {
    final id = itemRef.getAttribute('idref');
    final item = id == null ? null : manifest[id];
    if (item == null ||
        !(item.mediaType.contains('xhtml') ||
            item.mediaType.contains('html'))) {
      continue;
    }
    final path = _resolveArchiveHref(baseDirectory, item.href);
    if (path.isEmpty) continue;
    final contentFile = archive.findFile(path);
    if (contentFile == null) continue;
    final source = _decodeXmlBytes(contentFile.content);
    final document = html_parser.parse(source);
    final body = document.body;
    if (body == null) continue;
    final chapterTitle =
        body.querySelector('h1, h2, h3, h4, h5, h6')?.text.trim() ?? '';
    final text = _normalizeHtmlText(_htmlNodeText(body));
    if (text.isEmpty) continue;
    // 只有标题、没有正文的文档（如 spine 里的 nav 目录页、只有标题的
    // 前言页）会让阅读器报“正文为空”，直接丢弃。
    if (chapterTitle.isNotEmpty &&
        text.replaceAll(RegExp(r'\s+'), '') ==
            chapterTitle.replaceAll(RegExp(r'\s+'), '')) {
      continue;
    }
    chapters.add(
      ParsedBookChapter(
        title: chapterTitle.isEmpty ? '第${chapters.length + 1}章' : chapterTitle,
        text: text,
      ),
    );
  }
  if (chapters.isEmpty) throw const FormatException('EPUB 中没有可阅读的章节');
  return ParsedImportedBook(
    title: title,
    author: author,
    format: 'epub',
    cover: cover,
    chapters: chapters,
  );
}

// ---------------------------------------------------------------------------
// EPUB cover extraction.
//
// The discovery order mirrors Legado's `EpubPackageParser.findCoverHref()`:
// declared artwork first, guesswork last, and the guesswork never degrades into
// "the first image in the manifest".
// ---------------------------------------------------------------------------

final _coverReferencePattern = RegExp(
  '''(?:src|href)\\s*=\\s*["']([^"']+)["']''',
  caseSensitive: false,
);
final _coverCssUrlPattern = RegExp(
  '''url\\(\\s*["']?([^"')]+)["']?\\s*\\)''',
  caseSensitive: false,
);
final _svgPattern = RegExp(r'<svg[\s>]', caseSensitive: false);

Set<String> _propertyTokens(String? value) {
  if (value == null) return const {};
  return value
      .split(RegExp(r'\s+'))
      .map((token) => token.trim().toLowerCase())
      .where((token) => token.isNotEmpty)
      .toSet();
}

bool _isImageMediaType(String mediaType) =>
    mediaType.trim().toLowerCase().startsWith('image/');

bool _isCoverDocumentMediaType(String mediaType) {
  final value = mediaType.split(';').first.trim().toLowerCase();
  return value == 'application/xhtml+xml' ||
      value == 'text/html' ||
      value == 'image/svg+xml';
}

/// Best-effort cover lookup: a damaged or unsupported artwork leaves the book
/// without a cover instead of failing the import.
ParsedBookCover? _extractEpubCover(
  List<XmlElement> opfElements,
  Map<String, ({String href, String mediaType, Set<String> properties})>
  manifest,
  String baseDirectory,
  Archive archive,
) {
  try {
    final href = _findCoverHref(opfElements, manifest, baseDirectory, archive);
    if (href == null) return null;
    return _loadCoverArtwork(href, baseDirectory, archive);
  } catch (_) {
    return null;
  }
}

String? _findCoverHref(
  List<XmlElement> opfElements,
  Map<String, ({String href, String mediaType, Set<String> properties})>
  manifest,
  String baseDirectory,
  Archive archive,
) {
  /// Accepts a manifest id as well as a resource path: producers write both
  /// into `<meta name="cover" content="..."/>`. A manifest href is already an
  /// archive path, so it is tried before resolving against the OPF folder.
  String? candidate(String? rawValue) {
    final value = rawValue?.trim() ?? '';
    if (value.isEmpty) return null;
    final byId = manifest[value.startsWith('#') ? value.substring(1) : value];
    if (byId != null) {
      final path = _resolveArchiveHref(baseDirectory, byId.href);
      if (path.isNotEmpty && archive.findFile(path) != null) return path;
    }
    if (value.startsWith('#')) return null;
    for (final path in [
      _resolveArchiveHref('', value),
      _resolveArchiveHref(baseDirectory, value),
    ]) {
      if (path.isNotEmpty && archive.findFile(path) != null) return path;
    }
    return null;
  }

  bool hinted(String id, String href) =>
      _coverHintPattern.hasMatch(id) || _coverHintPattern.hasMatch(href);

  // EPUB 3 marks the manifest item itself.
  for (final item in manifest.values) {
    if (!item.properties.contains('cover-image')) continue;
    final found = candidate(item.href);
    if (found != null) return found;
  }

  // Some producers declare it in metadata instead, optionally refining an id.
  for (final meta in opfElements.where((e) => e.localName == 'meta')) {
    final property = meta.getAttribute('property')?.trim().toLowerCase();
    if (property != 'cover-image') continue;
    final text = meta.innerText.trim();
    final found =
        candidate(meta.getAttribute('refines')) ??
        candidate(text.isNotEmpty ? text : meta.getAttribute('content'));
    if (found != null) return found;
  }

  // EPUB 2 uses `<meta name="cover" content="manifest-id">`, and a number of
  // files put a relative resource path there instead.
  for (final meta in opfElements.where((e) => e.localName == 'meta')) {
    final name = meta.getAttribute('name')?.trim().toLowerCase();
    if (name != 'cover') continue;
    final found = candidate(meta.getAttribute('content'));
    if (found != null) return found;
    // Only the first such entry is trusted; later ones are the kind of noise
    // that would otherwise resurrect an unrelated title page.
    break;
  }

  // EPUB 2 commonly points at a cover document through guide. Kept behind the
  // explicit declarations because guide may hold a presentation-only title
  // page rather than the artwork.
  for (final reference in opfElements.where(
    (e) => e.localName == 'reference',
  )) {
    final type = reference.getAttribute('type')?.trim().toLowerCase();
    if (type != 'cover') continue;
    final found = candidate(reference.getAttribute('href'));
    if (found != null) return found;
    break;
  }

  // Packages omitting both declarations: limit the guesswork to resources whose
  // id or path actually carries a cover hint.
  for (final entry in manifest.entries) {
    final item = entry.value;
    if (!_isImageMediaType(item.mediaType)) continue;
    if (!hinted(entry.key, item.href)) continue;
    final found = candidate(item.href);
    if (found != null) return found;
  }
  for (final entry in manifest.entries) {
    final item = entry.value;
    if (!_isCoverDocumentMediaType(item.mediaType)) continue;
    if (!hinted(entry.key, item.href)) continue;
    final found = candidate(item.href);
    if (found != null) return found;
  }
  return null;
}

/// Reads the artwork and returns it in the stored shape. Raster images are
/// re-encoded; a cover document that only wraps the real artwork is followed one
/// level, which is what keeps SVG/XHTML covers from drawing blank.
ParsedBookCover? _loadCoverArtwork(
  String href,
  String baseDirectory,
  Archive archive,
) {
  final bytes = _readCoverBytes(href, archive);
  if (bytes == null) return null;
  final raster = _encodeRasterCover(bytes);
  if (raster != null) return raster;
  final directory = href.contains('/')
      ? href.substring(0, href.lastIndexOf('/'))
      : baseDirectory;
  for (final reference in _coverReferences(bytes)) {
    final path = _resolveArchiveHref(directory, reference);
    if (path.isEmpty || path == href) continue;
    final nested = _readCoverBytes(path, archive);
    if (nested == null) continue;
    final image = _encodeRasterCover(nested);
    if (image != null) return image;
  }
  if (_looksLikeSvg(bytes)) {
    return ParsedBookCover(bytes: bytes, extension: 'svg');
  }
  return null;
}

Uint8List? _readCoverBytes(String path, Archive archive) {
  final file = archive.findFile(path);
  if (file == null) return null;
  final content = file.content;
  if (content.isEmpty || content.length > _maxCoverResourceBytes) return null;
  return content;
}

String? _rasterFormat(Uint8List bytes) {
  if (_startsWithBytes(bytes, const [0x89, 0x50, 0x4e, 0x47])) return 'png';
  if (_startsWithBytes(bytes, const [0xff, 0xd8, 0xff])) return 'jpg';
  if (_startsWithBytes(bytes, const [0x47, 0x49, 0x46, 0x38])) return 'gif';
  if (_startsWithBytes(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
      _startsWithBytes(bytes, const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'webp';
  }
  return null;
}

bool _startsWithBytes(Uint8List bytes, List<int> magic, [int offset = 0]) {
  if (bytes.length < offset + magic.length) return false;
  for (var index = 0; index < magic.length; index++) {
    if (bytes[offset + index] != magic[index]) return false;
  }
  return true;
}

/// Re-encodes raster artwork, or returns null when the payload is not a bitmap.
/// The format comes from the magic number rather than the declared media type —
/// the same last gate Legado applies before storing a cover.
ParsedBookCover? _encodeRasterCover(Uint8List bytes) {
  if (_rasterFormat(bytes) == null) return null;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final wide = decoded.width >= decoded.height;
  final scaled =
      decoded.width > _maxCoverImageEdge || decoded.height > _maxCoverImageEdge
      ? img.copyResize(
          decoded,
          width: wide ? _maxCoverImageEdge : null,
          height: wide ? null : _maxCoverImageEdge,
        )
      : decoded;
  if (_hasTransparentPixel(scaled)) {
    return ParsedBookCover(bytes: img.encodePng(scaled), extension: 'png');
  }
  return ParsedBookCover(
    bytes: img.encodeJpg(scaled, quality: _coverJpegQuality),
    extension: 'jpg',
  );
}

/// Bounded alpha scan: artwork without real transparency is stored as JPEG,
/// which is what keeps the private directory small. The cap mirrors the scan
/// limit Legado applies before choosing between the two.
bool _hasTransparentPixel(img.Image image) {
  if (image.numChannels != 4 && image.numChannels != 2) return false;
  final total = image.width * image.height;
  if (total <= 0) return false;
  final step = total <= _maxCoverAlphaScanPixels
      ? 1
      : (total / _maxCoverAlphaScanPixels).ceil();
  for (var index = 0; index < total; index += step) {
    if (image.getPixel(index % image.width, index ~/ image.width).a < 255) {
      return true;
    }
  }
  return false;
}

/// Resource references a cover document may wrap the real artwork in.
Iterable<String> _coverReferences(Uint8List bytes) sync* {
  if (bytes.length > _maxCoverDocumentBytes) return;
  final source = _decodeXmlBytes(bytes);
  for (final pattern in [_coverReferencePattern, _coverCssUrlPattern]) {
    for (final match in pattern.allMatches(source)) {
      final value = match.group(1);
      if (value != null && value.isNotEmpty) yield value;
    }
  }
}

bool _looksLikeSvg(Uint8List bytes) {
  if (bytes.length > _maxCoverDocumentBytes) return false;
  final head = bytes.length <= 2048 ? bytes : bytes.sublist(0, 2048);
  return _svgPattern.hasMatch(_decodeXmlBytes(head));
}

XmlElement? _firstElement(XmlDocument document, String localName) {
  for (final element
      in document.rootElement.descendants.whereType<XmlElement>()) {
    if (element.localName == localName) return element;
  }
  return null;
}

void _checkEpubZipLimits(Uint8List bytes) {
  if (bytes.length < 22) throw const FormatException('EPUB 文件不是有效的 ZIP');
  final view = ByteData.sublistView(bytes);
  final minOffset = max(0, bytes.length - 65557);
  var endOffset = -1;
  for (var offset = bytes.length - 22; offset >= minOffset; offset--) {
    if (view.getUint32(offset, Endian.little) == 0x06054b50) {
      endOffset = offset;
      break;
    }
  }
  if (endOffset < 0) throw const FormatException('EPUB ZIP 目录损坏');
  final entries = view.getUint16(endOffset + 10, Endian.little);
  final directorySize = view.getUint32(endOffset + 12, Endian.little);
  final directoryOffset = view.getUint32(endOffset + 16, Endian.little);
  if (entries == 0xffff ||
      directorySize == 0xffffffff ||
      directoryOffset == 0xffffffff) {
    throw const FormatException('暂不支持 ZIP64 格式 EPUB');
  }
  if (entries > _maxEpubEntries ||
      directoryOffset + directorySize > endOffset) {
    throw const FormatException('EPUB 目录超出支持范围');
  }
  var offset = directoryOffset;
  var expandedBytes = 0;
  for (var index = 0; index < entries; index++) {
    if (offset + 46 > bytes.length ||
        view.getUint32(offset, Endian.little) != 0x02014b50) {
      throw const FormatException('EPUB ZIP 目录条目损坏');
    }
    final compressed = view.getUint32(offset + 20, Endian.little);
    final expanded = view.getUint32(offset + 24, Endian.little);
    final nameLength = view.getUint16(offset + 28, Endian.little);
    final extraLength = view.getUint16(offset + 30, Endian.little);
    final commentLength = view.getUint16(offset + 32, Endian.little);
    if (compressed == 0xffffffff || expanded == 0xffffffff) {
      throw const FormatException('暂不支持 ZIP64 格式 EPUB');
    }
    if (compressed == 0 && expanded > 0 ||
        compressed > 0 && expanded / compressed > 1000) {
      throw const FormatException('EPUB 压缩比例异常');
    }
    expandedBytes += expanded;
    if (expandedBytes > _maxExpandedEpubBytes) {
      throw const FormatException('EPUB 解压后超过 64 MB');
    }
    offset += 46 + nameLength + extraLength + commentLength;
    if (offset > directoryOffset + directorySize) {
      throw const FormatException('EPUB ZIP 目录条目越界');
    }
  }
}

String _resolveArchiveHref(String baseDirectory, String href) {
  final withoutSuffix = href.split('#').first.split('?').first;
  if (withoutSuffix.isEmpty || Uri.tryParse(withoutSuffix)?.hasScheme == true) {
    return '';
  }
  String decoded;
  try {
    decoded = Uri.decodeComponent(withoutSuffix).replaceAll('\\', '/');
  } on FormatException {
    return '';
  }
  final parts = <String>[];
  if (!decoded.startsWith('/')) {
    parts.addAll(baseDirectory.split('/').where((part) => part.isNotEmpty));
  }
  parts.addAll(decoded.split('/'));
  return _normalizeArchivePath(parts.join('/'));
}

String _normalizeArchivePath(String path) {
  final parts = <String>[];
  for (final part in path.replaceAll('\\', '/').split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

String _htmlNodeText(dom.Node node) {
  if (node is dom.Text) return node.data;
  if (node is! dom.Element) return '';
  final tag = node.localName;
  if (const {'script', 'style', 'noscript', 'nav'}.contains(tag)) return '';
  if (tag == 'br') return '\n';
  final block = const {
    'address',
    'article',
    'aside',
    'blockquote',
    'dd',
    'div',
    'dl',
    'dt',
    'figcaption',
    'figure',
    'footer',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'header',
    'li',
    'main',
    'ol',
    'p',
    'section',
    'table',
    'tr',
    'ul',
  }.contains(tag);
  final body = node.nodes.map(_htmlNodeText).join();
  return block ? '\n$body\n' : body;
}

String _normalizeHtmlText(String value) => value
    .replaceAll('\r', '')
    .split('\n')
    .map((line) => line.replaceAll(RegExp(r'[\t\u00a0 ]+'), ' ').trim())
    .where((line) => line.isNotEmpty)
    .join('\n\n')
    .trim();

String _decodeXmlBytes(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }
  var start =
      bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf
      ? 3
      : 0;
  return utf8.decode(bytes.sublist(start), allowMalformed: true);
}

String _decodeText(Uint8List bytes) => _decodeXmlBytes(bytes);

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var offset = 0; offset + 1 < bytes.length; offset += 2) {
    units.add(
      littleEndian
          ? bytes[offset] | (bytes[offset + 1] << 8)
          : (bytes[offset] << 8) | bytes[offset + 1],
    );
  }
  if (bytes.length.isOdd) units.add(0xfffd);
  return String.fromCharCodes(units);
}

String _fileTitle(String fileName) {
  final leaf = fileName.replaceAll('\\', '/').split('/').last;
  final dot = leaf.lastIndexOf('.');
  final name = (dot > 0 ? leaf.substring(0, dot) : leaf).trim();
  return name.isEmpty ? '未命名书籍' : name;
}
