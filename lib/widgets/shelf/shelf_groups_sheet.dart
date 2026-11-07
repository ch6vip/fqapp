// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/book_categories.dart -> showShelfGroupsSheet (showBookCategories),
//                               chooseShelfCategory (chooseBookCategory),
//                               _CategoryNameSheet (_GroupNameSheet)
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - `LocalLibraryPreferences` -> `ShelfGroupStore` (the frozen U1 store). All
//   reads/writes go through the store; this file never touches Hive.
// - `showJellySheet`/`confirmNovelAction` -> `wenku_overlay.dart`'s
//   `showJellySheet`/`confirmArchiveAction` (the same upstream jelly sheet and
//   confirmation, decisions #10/#17).
// - `showNovelFeedback` -> `shelf_feedback.dart`'s `showShelfFeedback`, which
//   inserts into the root Overlay so the notice stays visible above the sheet.
// - `app_ui.dart` AppText -> `src/app_text.dart`; ArchiveSection/ArchiveIcon ->
//   `wenku_archive.dart`/`wenku_icons.dart`; GlassTextButton/GlassIconButton/
//   GlassPillButton -> `wenku_glass.dart`.
// - `Novel` -> `MediaItem`; author counts use `shelfAuthorName`.
//
// fqapp additions:
// - `showShelfGroupsSheet` returns the chosen category, and after creating or
//   renaming a group returns that group id so the caller can select it.
// - A not-ready store renders a read-only notice instead of throwing
//   (D-M4: never write a fallback category back to disk).
// - Deleting the currently selected group returns `_all`.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../models/shelf_categories.dart';
import '../../services/shelf_group_store.dart';
import '../wenku/src/app_text.dart';
import '../wenku/wenku_archive.dart';
import '../wenku/wenku_glass.dart';
import '../wenku/wenku_overlay.dart';
import 'shelf_feedback.dart';

/// Opens the full category manager: choose, create, rename, delete, or pick an
/// author category. Returns the chosen category (or null when dismissed).
Future<String?> showShelfGroupsSheet(
  BuildContext context, {
  required ShelfGroupStore store,
  required String selected,
  required bool reduceMotion,
  required List<MediaItem> items,
}) async {
  if (!store.isReady) {
    return showJellySheet<String>(
      context: context,
      reduceMotion: reduceMotion,
      heightFactor: .5,
      builder: (sheet) => const _ReadOnlyCategories(),
    );
  }
  final result = await showJellySheet<String>(
    context: context,
    reduceMotion: reduceMotion,
    heightFactor: .72,
    builder: (sheet) => _CategoriesSheet(store: store, selected: selected),
  );
  if (!context.mounted || result == null) return null;
  try {
    if (result == '_authors') {
      return await _chooseAuthor(
        context,
        items: items,
        selected: selected,
        reduceMotion: reduceMotion,
      );
    }
    if (result == '_new' || result.startsWith('rename:')) {
      final id = result == '_new' ? null : result.substring(7);
      final saved = await showJellySheet<String>(
        context: context,
        reduceMotion: reduceMotion,
        heightFactor: .58,
        builder: (_) => _GroupNameSheet(store: store, id: id),
      );
      return saved;
    }
    if (result.startsWith('delete:')) {
      final id = result.substring(7);
      final confirmed = await confirmArchiveAction(
        context,
        title: '删除这个分类？',
        message: '书籍会回到未分类，原书与阅读记录保留。',
        confirmLabel: '删除分类',
        reduceMotion: reduceMotion,
      );
      if (!confirmed) return null;
      await store.removeGroup(id);
      return id == selected ? ShelfCategory.all : null;
    }
    return result;
  } catch (error) {
    if (context.mounted) {
      showShelfFeedback(
        context,
        error is FormatException ? error.message : '分类保存失败，请重试',
      );
    }
    return null;
  }
}

/// Opens the assignment sheet for selected books. Returns the category to
/// assign, or null when dismissed.
Future<String?> chooseShelfCategory(
  BuildContext context, {
  required ShelfGroupStore store,
  required String selected,
  bool reduceMotion = false,
}) async {
  // An assignment target must be a real, visible group. `_ReadOnlyCategories`
  // exists for the filter sheet, where `_all` is valid; reusing it here would
  // hand the caller `_all`, which `ShelfGroupStore.assignKeys` rejects (and a
  // not-ready store throws before that). Keep the selection unchanged instead.
  if (!store.isReady) return null;
  final result = await showJellySheet<String>(
    context: context,
    reduceMotion: reduceMotion,
    heightFactor: .6,
    builder: (sheet) => _AssignSheet(store: store, selected: selected),
  );
  if (!context.mounted || result == null) return null;
  if (result != '_new') return result;
  final created = await showJellySheet<String>(
    context: context,
    reduceMotion: reduceMotion,
    heightFactor: .58,
    builder: (_) => _GroupNameSheet(store: store),
  );
  return created;
}

Future<String?> _chooseAuthor(
  BuildContext context, {
  required List<MediaItem> items,
  required String selected,
  required bool reduceMotion,
}) {
  final counts = <String, int>{};
  for (final item in items) {
    final author = shelfAuthorName(item.author);
    counts[author] = (counts[author] ?? 0) + 1;
  }
  final authors = counts.keys.toList()..sort();
  return showJellySheet<String>(
    context: context,
    reduceMotion: reduceMotion,
    heightFactor: .72,
    builder: (sheet) => ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        const ArchiveSection(title: '按作者分类', code: 'LIBRARY / AUTHORS'),
        const SizedBox(height: 16),
        if (authors.isEmpty) const AppText('当前书库暂无作者信息'),
        for (final author in authors)
          GlassTextButton(
            key: ValueKey('category-author-$author'),
            selected: selected == shelfAuthorCategory(author),
            onPressed: () => Navigator.pop(sheet, shelfAuthorCategory(author)),
            child: Row(
              children: [
                Expanded(child: AppText(author)),
                const SizedBox(width: 12),
                AppText(
                  '${counts[author]} 本',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// The category list with per-group rename/delete actions.
class _CategoriesSheet extends StatelessWidget {
  const _CategoriesSheet({required this.store, required this.selected});
  final ShelfGroupStore store;
  final String selected;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const ArchiveSection(title: '书籍分类', code: 'LIBRARY / CATEGORIES'),
        const SizedBox(height: 16),
        for (final entry in {
          ShelfCategory.all: '全部书籍',
          ShelfCategory.unfiled: '未分类',
          ...store.groups,
        }.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: GlassTextButton(
                    onPressed: () => Navigator.pop(context, entry.key),
                    child: AppText(
                      '${entry.key == selected ? '✓  ' : ''}${entry.value}',
                    ),
                  ),
                ),
                if (!entry.key.startsWith('_')) ...[
                  const SizedBox(width: 8),
                  GlassIconButton(
                    icon: CupertinoIcons.pencil,
                    label: '重命名 ${entry.value}',
                    onPressed: () =>
                        Navigator.pop(context, 'rename:${entry.key}'),
                  ),
                  const SizedBox(width: 8),
                  GlassIconButton(
                    icon: CupertinoIcons.trash,
                    label: '删除分类 ${entry.value}',
                    onPressed: () =>
                        Navigator.pop(context, 'delete:${entry.key}'),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 12),
        GlassTextButton(
          key: const ValueKey('category-by-author'),
          onPressed: () => Navigator.pop(context, '_authors'),
          child: const AppText('按作者分类'),
        ),
        const SizedBox(height: 12),
        GlassPillButton(
          icon: CupertinoIcons.plus,
          label: '新建分类',
          onPressed: () => Navigator.pop(context, '_new'),
        ),
      ],
    ),
  );
}

/// The assignment list: unfiled + groups + create.
class _AssignSheet extends StatelessWidget {
  const _AssignSheet({required this.store, required this.selected});
  final ShelfGroupStore store;
  final String selected;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
    children: [
      const ArchiveSection(title: '移至分类', code: 'LIBRARY / ORGANIZE'),
      const SizedBox(height: 16),
      for (final entry in {
        ShelfCategory.unfiled: '未分类',
        ...store.groups,
      }.entries)
        GlassTextButton(
          onPressed: () => Navigator.pop(context, entry.key),
          child: AppText('${entry.key == selected ? '✓  ' : ''}${entry.value}'),
        ),
      const SizedBox(height: 12),
      GlassPillButton(
        icon: CupertinoIcons.plus,
        label: '新建分类',
        onPressed: () => Navigator.pop(context, '_new'),
      ),
    ],
  );
}

/// A read-only notice for a store whose box is not open yet.
class _ReadOnlyCategories extends StatelessWidget {
  const _ReadOnlyCategories();

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const ArchiveSection(title: '书籍分类', code: 'LIBRARY / CATEGORIES'),
        const SizedBox(height: 16),
        const AppText('分类暂不可用，请稍后再试'),
        const SizedBox(height: 12),
        GlassTextButton(
          onPressed: () => Navigator.pop(context, ShelfCategory.all),
          child: const AppText('全部书籍'),
        ),
      ],
    ),
  );
}

/// Create or rename a group; pops with the group id on success.
class _GroupNameSheet extends StatefulWidget {
  const _GroupNameSheet({required this.store, this.id});
  final ShelfGroupStore store;
  final String? id;

  @override
  State<_GroupNameSheet> createState() => _GroupNameSheetState();
}

class _GroupNameSheetState extends State<_GroupNameSheet> {
  late final _text = TextEditingController(
    text: widget.id == null ? '' : widget.store.groups[widget.id],
  );
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final id = widget.id == null
          ? await widget.store.addGroup(_text.text)
          : widget.id!;
      if (widget.id != null) {
        await widget.store.renameGroup(widget.id!, _text.text);
      }
      if (mounted) Navigator.pop(context, id);
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        showShelfFeedback(
          context,
          error is FormatException ? error.message : '分类保存失败',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ArchiveSection(
          title: widget.id == null ? '新建分类' : '重命名分类',
          code: 'LIBRARY / CATEGORY',
        ),
        const SizedBox(height: 20),
        CupertinoTextField(
          controller: _text,
          enabled: !_busy,
          placeholder: '分类名称',
          maxLength: 30,
          padding: const EdgeInsets.all(16),
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        ),
        const SizedBox(height: 18),
        GlassPillButton(
          icon: CupertinoIcons.checkmark,
          label: '保存分类',
          onPressed: _busy ? null : _save,
        ),
      ],
    ),
  );
}
