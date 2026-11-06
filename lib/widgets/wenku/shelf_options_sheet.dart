// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/book_collection_view_options.dart -> ShelfViewOptions,
//                                            ShelfFilterOptions,
//                                            ShelfToggle, ShelfCountSetting
//   lib/book_grid_density_controls.dart   -> ShelfGridDensityOptions
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - `app_ui.dart` AppText -> `src/app_text.dart`; ArchiveSection/ArchiveIcon ->
//   `wenku_archive.dart`/`wenku_icons.dart`; GlassTextButton/GlassIconButton ->
//   `wenku_glass.dart`; GlassChoiceGroup -> `wenku_segments.dart`.
// - `setting_menu.dart` GlassSettingMenu is not ported: the frozen shelf sheet
//   exposes the four modes, density, counts and repeat-fill only, so no
//   secondary anchored menu is needed.
// - `BookShelfContentPreferences` follow toggle is intentionally absent
//   (decisions #9: followCollection is fixed true and the UI never exposes it).
// - `showNovelFeedback` -> `shelf_feedback.dart`'s `showShelfFeedback`, which
//   inserts into the root Overlay so the notice stays visible above the sheet.
//
// fqapp additions:
// - `ShelfViewTarget` is the frozen three-target enum; `all` shows the four
//   modes, `shelf` shows only the upper-region preferences, `collection` shows
//   the list/grid toggle and density.
// - `ShelfCountSetting.inputKey` lets the page pin the text field's key.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/shelf_view_state.dart';
import '../shelf/shelf_feedback.dart';
import 'book_collection_layout.dart';
import 'src/app_text.dart';
import 'wenku_archive.dart';
import 'wenku_glass.dart';
import 'wenku_icons.dart';
import 'wenku_reveal.dart';
import 'wenku_segments.dart';

/// Region-specific view sheets never change the other region's presentation.
enum ShelfViewTarget { all, shelf, collection }

/// Shared view controls for the shelf and collection tabs.
class ShelfViewOptions extends StatelessWidget {
  const ShelfViewOptions({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.density,
    required this.onDensityChanged,
    this.preferences = const BookShelfPreferences.defaults(),
    this.onPreferencesChanged,
    this.gridViewport,
    this.target = ShelfViewTarget.all,
    this.onShowLayoutOptions,
  });
  final BookCollectionMode mode;
  final ValueChanged<BookCollectionMode> onModeChanged;
  final BookGridDensity density;
  final ValueChanged<BookGridDensity> onDensityChanged;
  final BookShelfPreferences preferences;
  final ValueChanged<BookShelfPreferences>? onPreferencesChanged;
  final BookGridViewport? gridViewport;
  final ShelfViewTarget target;
  final VoidCallback? onShowLayoutOptions;

  static IconData iconFor(BookCollectionMode mode) => switch (mode) {
    BookCollectionMode.list => CupertinoIcons.list_bullet,
    BookCollectionMode.shelfList => CupertinoIcons.rectangle_grid_1x2,
    BookCollectionMode.shelfGrid => CupertinoIcons.rectangle_grid_2x2,
    BookCollectionMode.grid => CupertinoIcons.square_grid_2x2,
  };

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      ArchiveSection(
        title: switch (target) {
          ShelfViewTarget.all => '整体布局',
          ShelfViewTarget.shelf => '立体书架视图',
          ShelfViewTarget.collection => '列表与宫格',
        },
        code: 'COLLECTION / VIEW',
      ),
      if (target == ShelfViewTarget.all)
        GlassChoiceGroup<BookCollectionMode>(
          name: 'collection-view',
          label: '布局',
          value: mode,
          options: {
            for (final value in BookCollectionMode.values) value: value.label,
          },
          optionName: (value) => value.storageValue,
          leading: (value) => ArchiveIcon(iconFor(value), size: 16),
          onChanged: onModeChanged,
        ),
      if (target == ShelfViewTarget.collection)
        GlassChoiceGroup<bool>(
          name: 'collection-region-view',
          label: '显示方式',
          value: mode.isGrid,
          options: const {false: '列表', true: '宫格'},
          leading: (grid) => ArchiveIcon(
            grid ? CupertinoIcons.square_grid_2x2 : CupertinoIcons.list_bullet,
            size: 16,
          ),
          onChanged: (grid) => onModeChanged(
            mode.hasShelf
                ? (grid
                      ? BookCollectionMode.shelfGrid
                      : BookCollectionMode.shelfList)
                : (grid ? BookCollectionMode.grid : BookCollectionMode.list),
          ),
        ),
      if (target != ShelfViewTarget.collection && onPreferencesChanged != null)
        AnimatedOptionSection(
          expanded: mode.hasShelf,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (target == ShelfViewTarget.all)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: AppText(
                        '上方 · 立体书架',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ShelfCountSetting(
                  key: const ValueKey('shelf-minimum-books'),
                  inputKey: const ValueKey('shelf-minimum-books-input'),
                  label: '显示所需最少本数',
                  value: preferences.minimumBooks,
                  onChanged: (value) => onPreferencesChanged!(
                    preferences.copyWith(minimumBooks: value),
                  ),
                ),
                const SizedBox(height: 8),
                ShelfCountSetting(
                  key: const ValueKey('shelf-maximum-books'),
                  inputKey: const ValueKey('shelf-maximum-books-input'),
                  label: '最多展示本数',
                  value: preferences.maximumBooks,
                  onChanged: (value) => onPreferencesChanged!(
                    preferences.copyWith(maximumBooks: value),
                  ),
                ),
                const SizedBox(height: 8),
                ShelfToggle(
                  key: const ValueKey('shelf-repeat-fill'),
                  label: '重复填充',
                  value: preferences.repeatFill,
                  onChanged: (value) => onPreferencesChanged!(
                    preferences.copyWith(repeatFill: value),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppText(
                    '关闭重复填充时，每本书只展示一次。展示本数不限制藏书数量。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      if (target != ShelfViewTarget.shelf)
        AnimatedOptionSection(
          expanded: mode.isGrid,
          child: ShelfGridDensityOptions(
            value: density,
            viewport: gridViewport,
            onChanged: onDensityChanged,
          ),
        ),
      if (target != ShelfViewTarget.all && onShowLayoutOptions != null) ...[
        const SizedBox(height: 20),
        GlassTextButton(
          key: const ValueKey('collection-all-layout-options'),
          onPressed: onShowLayoutOptions,
          child: const AppText('整体布局'),
        ),
      ],
    ],
  );
}

/// Reading-state, source and sort filters for the shelf's lower collection.
class ShelfFilterOptions extends StatelessWidget {
  const ShelfFilterOptions({
    super.key,
    required this.sort,
    required this.reading,
    required this.source,
    required this.onSort,
    required this.onReading,
    required this.onSource,
    this.sourceOptions = const {
      'all': '全部',
      'local': '本地导入',
      'cached': '已缓存',
      'online': '在线收藏',
    },
    this.cachedAvailable = true,
  });
  final ShelfSort sort;
  final ShelfReadingFilter reading;
  final ShelfSourceFilter source;
  final ValueChanged<ShelfSort> onSort;
  final ValueChanged<ShelfReadingFilter> onReading;
  final ValueChanged<ShelfSourceFilter> onSource;
  final Map<String, String> sourceOptions;

  /// False while the offline-cache scan is running: the cached option stays
  /// visible but cannot be chosen.
  final bool cachedAvailable;

  @override
  Widget build(BuildContext context) {
    final sources = <ShelfSourceFilter, String>{};
    for (final entry in sourceOptions.entries) {
      final value = ShelfSourceFilter.tryParse(entry.key);
      if (value != null) sources[value] = entry.value;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const ArchiveSection(title: '筛选', code: 'LIBRARY / FILTER'),
        GlassChoiceGroup<ShelfReadingFilter>(
          name: 'shelf-filter-reading',
          label: '阅读状态',
          value: reading,
          options: const {
            ShelfReadingFilter.all: '全部',
            ShelfReadingFilter.unread: '未读',
            ShelfReadingFilter.reading: '阅读中',
            ShelfReadingFilter.finished: '已读完',
          },
          optionName: (value) => value.storageValue,
          onChanged: onReading,
        ),
        if (sources.isNotEmpty)
          GlassChoiceGroup<ShelfSourceFilter>(
            name: 'shelf-filter-source',
            label: '书籍来源',
            value: source,
            options: sources,
            optionName: (value) => value.storageValue,
            disabledOptions: cachedAvailable
                ? const {}
                : const {ShelfSourceFilter.cached},
            onChanged: onSource,
          ),
        GlassChoiceGroup<ShelfSort>(
          name: 'shelf-filter-sort',
          label: '排列顺序',
          value: sort,
          options: const {
            ShelfSort.recentRead: '最近阅读',
            ShelfSort.recentAdded: '最近加入',
            ShelfSort.title: '书名',
          },
          optionName: (value) => value.storageValue,
          onChanged: onSort,
        ),
      ],
    );
  }
}

/// Cover-size presets for the grid modes.
class ShelfGridDensityOptions extends StatelessWidget {
  const ShelfGridDensityOptions({
    super.key,
    required this.value,
    required this.onChanged,
    this.viewport,
  });
  final BookGridDensity value;
  final ValueChanged<BookGridDensity> onChanged;
  final BookGridViewport? viewport;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.only(top: 14, bottom: 4),
        child: AppText(
          '封面大小',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final preset in const [
            BookGridDensity.auto(),
            BookGridDensity.sized(BookGridSize.small),
            BookGridDensity.sized(BookGridSize.medium),
            BookGridDensity.sized(BookGridSize.large),
          ])
            Semantics(
              selected: value == preset,
              inMutuallyExclusiveGroup: true,
              child: GlassTextButton(
                key: ValueKey('grid-density-${preset.value}'),
                compact: true,
                selected: value == preset,
                onPressed: () => onChanged(preset),
                child: AppText(
                  preset.label,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
        ],
      ),
    ],
  );
}

/// A labelled integer stepper used by the upper shelf's count preferences.
class ShelfCountSetting extends StatefulWidget {
  const ShelfCountSetting({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.inputKey,
  });
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final Key? inputKey;

  @override
  State<ShelfCountSetting> createState() => _ShelfCountSettingState();
}

class _ShelfCountSettingState extends State<ShelfCountSetting> {
  late final _text = TextEditingController(text: '${widget.value}');
  late final _focus = FocusNode()..addListener(_focusChanged);

  void _focusChanged() {
    if (!_focus.hasFocus) _finish();
  }

  void _finish() {
    final value = int.tryParse(_text.text);
    if (value == null || value < 1 || value > BookShelfPreferences.maximum) {
      _text.text = '${widget.value}';
      _feedback('请输入 1–100 本');
      return;
    }
    _commit(value);
  }

  void _commit(int value) {
    _text.text = '$value';
    if (value != widget.value) widget.onChanged(value);
  }

  void _step(int delta) {
    final value = int.tryParse(_text.text) ?? widget.value;
    _commit((value + delta).clamp(1, BookShelfPreferences.maximum));
  }

  void _feedback(String message) => showShelfFeedback(context, message);

  @override
  void didUpdateWidget(ShelfCountSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus) _text.text = '${widget.value}';
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: AppText(widget.label, style: const TextStyle(fontSize: 13)),
      ),
      const SizedBox(width: 8),
      GlassIconButton(
        icon: CupertinoIcons.minus,
        label: '减少${widget.label}',
        onPressed: widget.value > 1 ? () => _step(-1) : null,
      ),
      SizedBox(
        width: 54,
        child: CupertinoTextField(
          key: widget.inputKey,
          controller: _text,
          focusNode: _focus,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(3),
          ],
          textAlign: TextAlign.center,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          decoration: const BoxDecoration(),
          onTap: () => _text.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _text.text.length,
          ),
          onTapOutside: (_) => _focus.unfocus(),
          onSubmitted: (_) => _focus.unfocus(),
        ),
      ),
      GlassIconButton(
        icon: CupertinoIcons.plus,
        label: '增加${widget.label}',
        onPressed: widget.value < BookShelfPreferences.maximum
            ? () => _step(1)
            : null,
      ),
    ],
  );
}

/// A label with the archive glass switch on the trailing edge.
class ShelfToggle extends StatelessWidget {
  const ShelfToggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: AppText(label, style: const TextStyle(fontSize: 13))),
      const SizedBox(width: 12),
      WenkuControls.toggle(context, value: value, onChanged: onChanged),
    ],
  );
}
