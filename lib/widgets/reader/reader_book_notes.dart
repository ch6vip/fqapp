import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/media_item.dart';
import '../../services/reader_bookmark_store.dart';
import '../../services/reader_preferences.dart';
import '../../services/reader_underline_store.dart';
import 'reader_theme.dart';

/// Device bookmarks and underlines, embedded in the parent's bounded book panel.
/// Navigation always receives the original record and its original coordinates.
class ReaderBookNotes extends StatefulWidget {
  const ReaderBookNotes({
    super.key,
    required this.bookId,
    required this.chapters,
    required this.preset,
    required this.bookmarkStore,
    required this.underlineStore,
    required this.onBookmark,
    required this.onUnderline,
    required this.onRangeUnderline,
  });

  final String bookId;
  final List<Chapter> chapters;
  final ReaderThemePreset preset;
  final ReaderBookmarkStore bookmarkStore;
  final ReaderUnderlineStore underlineStore;
  final ValueChanged<ReaderBookmark> onBookmark;
  final ValueChanged<ReaderUnderline> onUnderline;
  final ValueChanged<ReaderRangeUnderline> onRangeUnderline;

  @override
  State<ReaderBookNotes> createState() => _ReaderBookNotesState();
}

enum _NotesFilter {
  all('全部'),
  bookmarks('书签'),
  underlines('划线');

  const _NotesFilter(this.label);
  final String label;
}

class _Note {
  const _Note(this.record);
  final Object record;

  String get chapterId => switch (record) {
    ReaderBookmark r => r.chapterId,
    ReaderUnderline r => r.chapterId,
    ReaderRangeUnderline r => r.chapterId,
    _ => throw StateError('Unsupported reading record'),
  };
  String get text => switch (record) {
    ReaderBookmark r => r.text,
    ReaderUnderline r => r.text,
    ReaderRangeUnderline r => r.text,
    _ => '',
  };
  int get time => switch (record) {
    ReaderBookmark r => r.createdAt,
    ReaderUnderline r => r.createdAt,
    ReaderRangeUnderline r => r.createdAt,
    _ => 0,
  };
  String get key => switch (record) {
    ReaderBookmark r => r.key,
    ReaderUnderline r => r.key,
    ReaderRangeUnderline r => r.key,
    _ => '',
  };
  bool get isBookmark => record is ReaderBookmark;
  String get type => switch (record) {
    ReaderBookmark() => '书签',
    ReaderUnderline() => '段落划线',
    _ => '选文划线',
  };
  String get identity => '${isBookmark ? 'bookmark' : 'underline'}:$key';
}

class _ReaderBookNotesState extends State<ReaderBookNotes> {
  List<_Note>? _records;
  _NotesFilter _filter = _NotesFilter.all;
  bool _loading = true;
  bool _deleting = false;
  String? _readError;
  _Note? _confirmDelete;
  _Note? _failedDelete;
  int _generation = 0;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _listen();
    unawaited(_load());
  }

  void _listen() {
    widget.bookmarkStore.changes.addListener(_changed);
    widget.underlineStore.changes.addListener(_changed);
  }

  @override
  void didUpdateWidget(ReaderBookNotes oldWidget) {
    super.didUpdateWidget(oldWidget);
    final switched =
        oldWidget.bookId != widget.bookId ||
        oldWidget.bookmarkStore != widget.bookmarkStore ||
        oldWidget.underlineStore != widget.underlineStore;
    if (switched) {
      oldWidget.bookmarkStore.changes.removeListener(_changed);
      oldWidget.underlineStore.changes.removeListener(_changed);
      _listen();
      _epoch++;
      _records = null;
      _confirmDelete = null;
      _failedDelete = null;
      _deleting = false;
      _filter = _NotesFilter.all;
    }
    if (switched) unawaited(_load());
  }

  void _changed() => unawaited(_load());

  Future<void> _load() async {
    final generation = ++_generation;
    final bookId = widget.bookId;
    final bookmarks = widget.bookmarkStore;
    final underlines = widget.underlineStore;
    setState(() {
      _loading = true;
      _readError = null;
    });
    try {
      final groups = await Future.wait<List<_Note>>([
        bookmarks
            .loadBook(bookId)
            .then((values) => values.map(_Note.new).toList()),
        underlines
            .loadBook(bookId)
            .then((values) => values.map(_Note.new).toList()),
        underlines
            .loadBookRanges(bookId)
            .then((values) => values.map(_Note.new).toList()),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _records = groups.expand((group) => group).toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _readError = '阅读记录读取失败，请重试';
        _loading = false;
      });
    }
  }

  Future<void> _delete(_Note note) async {
    if (_deleting) return;
    final epoch = _epoch;
    final bookmarks = widget.bookmarkStore;
    final underlines = widget.underlineStore;
    setState(() {
      _deleting = true;
      _failedDelete = null;
      _confirmDelete = note;
    });
    try {
      if (note.isBookmark) {
        await bookmarks.remove(note.key);
      } else {
        await underlines.remove(note.key);
      }
      if (!mounted || epoch != _epoch) return;
      setState(() => _confirmDelete = null);
      await _load();
    } catch (_) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _confirmDelete = null;
        _failedDelete = note;
      });
    } finally {
      if (mounted && epoch == _epoch) setState(() => _deleting = false);
    }
  }

  void _open(_Note note) {
    switch (note.record) {
      case ReaderBookmark record:
        widget.onBookmark(record);
      case ReaderUnderline record:
        widget.onUnderline(record);
      case ReaderRangeUnderline record:
        widget.onRangeUnderline(record);
    }
  }

  @override
  void dispose() {
    _generation++;
    _epoch++;
    widget.bookmarkStore.changes.removeListener(_changed);
    widget.underlineStore.changes.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: widget.preset.theme(Theme.of(context)),
    child: Builder(builder: _buildContent),
  );

  Widget _buildContent(BuildContext context) {
    final preset = widget.preset;
    final chapters = {for (final c in widget.chapters) c.itemId: c};
    final order = <String, int>{};
    for (final chapter in widget.chapters) {
      order.putIfAbsent(chapter.itemId, () => order.length);
    }
    final visible =
        (_records ?? const <_Note>[])
            .where(
              (note) => switch (_filter) {
                _NotesFilter.all => true,
                _NotesFilter.bookmarks => note.isBookmark,
                _NotesFilter.underlines => !note.isBookmark,
              },
            )
            .toList()
          ..sort((a, b) {
            final chapterOrder = (order[a.chapterId] ?? order.length).compareTo(
              order[b.chapterId] ?? order.length,
            );
            if (chapterOrder != 0) return chapterOrder;
            final chapterIdOrder = a.chapterId.compareTo(b.chapterId);
            if (chapterIdOrder != 0) return chapterIdOrder;
            final timeOrder = b.time.compareTo(a.time);
            return timeOrder == 0
                ? a.identity.compareTo(b.identity)
                : timeOrder;
          });
    final rows = <Object>[];
    String? previous;
    for (final note in visible) {
      if (note.chapterId != previous) {
        final chapter = chapters[note.chapterId];
        rows.add((
          note.chapterId,
          chapter?.title ?? '目录外章节',
          chapter == null ? '章节编号：${note.chapterId}' : chapter.volumeName,
        ));
        previous = note.chapterId;
      }
      rows.add(note);
    }
    return Material(
      color: Colors.transparent,
      child: CustomScrollView(
        key: const ValueKey('reader-book-notes-scroll'),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final filter in _NotesFilter.values)
                    ChoiceChip(
                      key: ValueKey('reader-book-notes-filter-${filter.name}'),
                      label: Text(filter.label),
                      selected: _filter == filter,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onSelected: (_) => setState(() => _filter = filter),
                    ),
                ],
              ),
            ),
          ),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ),
          if (_readError != null)
            SliverToBoxAdapter(
              child: _feedback(
                context,
                _readError!,
                '重新读取',
                _loading ? null : () => unawaited(_load()),
                'reader-book-notes-reload',
              ),
            ),
          if (_failedDelete case final failed?)
            SliverToBoxAdapter(
              child: _feedback(
                context,
                '${failed.type}删除失败，记录仍保留',
                '重试删除',
                _deleting ? null : () => unawaited(_delete(failed)),
                'reader-book-notes-retry-delete',
              ),
            ),
          if (!_loading && _readError == null && visible.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  switch (_filter) {
                    _NotesFilter.all => '本书还没有书签或划线',
                    _NotesFilter.bookmarks => '本书还没有书签',
                    _NotesFilter.underlines => '本书还没有划线',
                  },
                  textAlign: TextAlign.center,
                  style: TextStyle(color: preset.textColor),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                if (row is _Note) return _card(context, row);
                final (id, title, volume) = row as (String, String, String);
                return Padding(
                  key: ValueKey('reader-book-notes-chapter-$id'),
                  padding: const EdgeInsets.only(top: 16, bottom: 12),
                  child: Semantics(
                    header: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: preset.textColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (volume.isNotEmpty)
                          Text(
                            volume,
                            style: TextStyle(
                              color: preset.textColor,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _feedback(
    BuildContext context,
    String message,
    String action,
    VoidCallback? onPressed,
    String key,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: TextStyle(color: widget.preset.textColor)),
          TextButton(
            key: ValueKey(key),
            onPressed: onPressed,
            child: Text(action),
          ),
        ],
      ),
    ),
  );

  Widget _card(BuildContext context, _Note note) {
    final preset = widget.preset;
    final confirming = _confirmDelete?.identity == note.identity;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        key: ValueKey('reader-book-notes-card-${note.identity}'),
        color: preset.fieldColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: preset.borderColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: InkWell(
                    key: ValueKey('reader-book-notes-open-${note.identity}'),
                    onTap: () => _open(note),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              Text(
                                note.type,
                                style: TextStyle(
                                  color: preset.textColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                _dateLabel(note.time),
                                style: TextStyle(
                                  color: preset.textColor,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            note.text.trim().isEmpty ? '已保存的阅读位置' : note.text,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: preset.textColor,
                              fontSize: 15,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: ValueKey('reader-book-notes-delete-${note.identity}'),
                  tooltip: '删除${note.type}',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  color: preset.textColor,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: _deleting
                      ? null
                      : () => setState(() {
                          _confirmDelete = note;
                          _failedDelete = null;
                        }),
                ),
              ],
            ),
            if (confirming)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '删除这条${note.type}？此操作不可撤销。',
                      style: TextStyle(color: preset.textColor),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          key: const ValueKey(
                            'reader-book-notes-cancel-delete',
                          ),
                          onPressed: _deleting
                              ? null
                              : () => setState(() => _confirmDelete = null),
                          child: const Text('取消'),
                        ),
                        TextButton(
                          key: const ValueKey(
                            'reader-book-notes-confirm-delete',
                          ),
                          onPressed: _deleting
                              ? null
                              : () => unawaited(_delete(note)),
                          child: Text(_deleting ? '正在删除…' : '确认删除'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _dateLabel(int milliseconds) {
    if (milliseconds <= 0) return '时间未记录';
    try {
      final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
      String two(int value) => value.toString().padLeft(2, '0');
      return '${date.year}/${two(date.month)}/${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
    } on ArgumentError {
      return '时间未记录';
    }
  }
}
