part of 'imported_book_store.dart';

/// Bounded LRU cache for parsed imported-book manifests.
///
/// [ImportedBookStore.chapterText] reads the whole `book.json` catalogue per
/// chapter without it; keeping only the books actually read avoids that without
/// letting the cache grow with the library. The least recently used entry is
/// evicted once [capacity] is exceeded.
class ImportedManifestCache<T extends Object> {
  ImportedManifestCache({this.capacity = 8});

  final int capacity;
  final _entries = <String, T>{};

  /// Returns the cached entry for [id] and marks it as recently used.
  T? operator [](String id) {
    final cached = _entries.remove(id);
    if (cached != null) _entries[id] = cached;
    return cached;
  }

  /// Stores [record] for [id], evicting the least recently used entry.
  void operator []=(String id, T record) {
    _entries.remove(id);
    _entries[id] = record;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Drops [id]; used when the book is deleted or imported again.
  void remove(String id) => _entries.remove(id);

  /// Number of entries currently cached.
  int get length => _entries.length;

  /// Returns [id] from the cache, otherwise awaits [load] and caches a hit.
  ///
  /// [load] resolving to null means the manifest is gone; that is reported to
  /// the caller rather than cached.
  Future<T> resolve(String id, Future<T?> Function() load) async {
    final cached = this[id];
    if (cached != null) return cached;
    final loaded = await load();
    if (loaded == null) throw const FileSystemException('找不到本地书籍');
    this[id] = loaded;
    return loaded;
  }
}

/// Decodes one `book.json` payload. Kept with the cache because both serve the
/// chapter-read path; the validation rules are unchanged from the old method.
ImportedBook? _importedBookFromManifest(
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
