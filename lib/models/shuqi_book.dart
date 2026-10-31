/// 书旗数据源的模型与解析。
///
/// 后端 `/api/v1/shuqi/*` 已经把上游字段归一化成稳定形状（见
/// `rust/src/endpoints/shuqi.rs`），所以这里只做类型包装，不再重做一遍字段兜底。
library;

import 'media_item.dart';

/// [MediaItem.source] 的书旗取值。
const String shuqiSourceId = 'shuqi';

/// 书旗 bookId 与番茄同为纯数字，只能靠来源字段区分。
bool isShuqiItem(MediaItem item) => item.source == shuqiSourceId;

String _text(Object? value) {
  if (value is String) return value;
  if (value == null) return '';
  return '$value';
}

int _int(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  return int.tryParse(_text(value)) ?? fallback;
}

List<String> _splitKinds(String raw) {
  if (raw.isEmpty) return const [];
  return raw
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

/// 搜索结果条目 → 通用 [MediaItem]。
///
/// 搜索列表、封面卡片与详情页头部都复用番茄那套组件，所以书旗结果也构造成
/// [MediaItem]，靠 [MediaItem.source] 区分来源。
MediaItem shuqiMediaItemFromSearch(Map<String, dynamic> json) {
  return MediaItem(
    id: _text(json['bookId']),
    title: _text(json['name']),
    cover: _text(json['coverUrl']),
    author: _text(json['author']),
    badge: '',
    ep: '',
    kind: 'book',
    intro: _text(json['intro']),
    categories: _splitKinds(_text(json['kind'])),
    source: shuqiSourceId,
  );
}

/// 书籍详情（`/api/v1/shuqi/book` 的 `data`）。
class ShuqiBook {
  final String bookId;
  final String name;
  final String author;
  final String intro;
  final String kind;
  final String coverUrl;
  final String wordCount;
  final String lastChapter;
  final String status;

  /// 总章数。目录走回退路径时用它递推，所以 0 表示详情没拿全。
  final int chapterTotalNum;

  const ShuqiBook({
    required this.bookId,
    required this.name,
    required this.author,
    required this.intro,
    required this.kind,
    required this.coverUrl,
    required this.wordCount,
    required this.lastChapter,
    required this.status,
    required this.chapterTotalNum,
  });

  factory ShuqiBook.fromJson(Map<String, dynamic> json) {
    return ShuqiBook(
      bookId: _text(json['bookId']),
      name: _text(json['name']),
      author: _text(json['author']),
      intro: _text(json['intro']),
      kind: _text(json['kind']),
      coverUrl: _text(json['coverUrl']),
      wordCount: _text(json['wordCount']),
      lastChapter: _text(json['lastChapter']),
      status: _text(json['status']),
      chapterTotalNum: _int(json['chapterTotalNum']),
    );
  }

  MediaItem toMediaItem() {
    return MediaItem(
      id: bookId,
      title: name,
      cover: coverUrl,
      author: author,
      badge: '',
      ep: '',
      kind: 'book',
      intro: intro,
      categories: _splitKinds(kind),
      source: shuqiSourceId,
    );
  }
}

/// 目录里的一章。
class ShuqiChapter {
  final String chapterId;
  final String title;
  final bool isVip;

  const ShuqiChapter({
    required this.chapterId,
    required this.title,
    required this.isVip,
  });
}

/// 目录响应的 `data`：`path` 是 "h5"（真章名）或 "index"（递推占位）。
class ShuqiToc {
  final String path;
  final int total;
  final List<ShuqiChapter> chapters;

  const ShuqiToc({
    required this.path,
    required this.total,
    required this.chapters,
  });

  /// 回退路径下的章名是「第N章」占位，界面据此提示。
  bool get hasRealTitles => path == 'h5';

  factory ShuqiToc.fromJson(Map<String, dynamic>? data) {
    final chapters = <ShuqiChapter>[];
    final raw = data?['chapters'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final map = Map<String, dynamic>.from(entry);
        final id = _text(map['chapterId']);
        if (id.isEmpty) continue;
        chapters.add(
          ShuqiChapter(
            chapterId: id,
            title: _text(map['title']),
            isVip: map['isVip'] == true,
          ),
        );
      }
    }
    return ShuqiToc(
      path: _text(data?['path']),
      total: _int(data?['total'], fallback: chapters.length),
      chapters: chapters,
    );
  }

  /// 转成阅读器认识的章节列表。`volumeName` 留空即单卷。
  List<Chapter> toReaderChapters() {
    return [
      for (final chapter in chapters)
        Chapter(
          itemId: chapter.chapterId,
          title: chapter.title,
          volumeName: '',
        ),
    ];
  }
}
