// Classic reader chrome (top toolbar + bottom sheet) for the 经典主题.
//
// Restored from the pre-#291 reader shell (fqapp-backup@f329399,
// `reader_page_build.dart:_buildToolbar` / `reader_controls.dart`), but display
// only: every entry calls the current `ReaderPage` callbacks. The two progress
// sliders keep their own meanings and never share a value:
//
// * 整书章节 (this file's `reader-chapter-seek`) only previews a *chapter
//   index*; the jump happens once, on release, through the page's
//   `_jumpToChapter`.
// * 本章进度 (`ReaderValueSlider` below) is the current chapter fraction and
//   keeps the live preview/commit lifecycle (`_previewChapterFraction` /
//   `_commitChapterFraction` / `_setChapterPreview`).
//
// No business logic, no chapter loading, no persistence lives here.
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';
import 'reader_value_slider.dart';

/// Top chrome: solid panel, back, book title + reading chapter, then the four
/// original actions.
///
/// Narrow screens scroll the action cluster sideways instead of dropping an
/// entry or overflowing the row; the title keeps at least half the width.
class ReaderClassicToolbar extends StatelessWidget {
  const ReaderClassicToolbar({
    super.key,
    required this.preset,
    required this.title,
    required this.chapterNumber,
    required this.showCache,
    required this.showComments,
    required this.inShelf,
    required this.onBack,
    required this.onCache,
    required this.onComments,
    required this.onShelf,
    required this.onCollapse,
  });

  final ReaderThemePreset preset;
  final String title;
  final int chapterNumber;
  final bool showCache;
  final bool showComments;
  final bool inShelf;
  final VoidCallback onBack;
  final VoidCallback onCache;
  final VoidCallback onComments;
  final VoidCallback onShelf;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('reader-classic-toolbar'),
    color: preset.panelColor,
    // Solid classic panel: an M3 elevation tint would otherwise repaint it.
    surfaceTintColor: Colors.transparent,
    elevation: 2,
    shadowColor: Colors.black12,
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              IconButton(
                key: const ValueKey('reader-back-entry'),
                tooltip: '返回书籍',
                onPressed: onBack,
                icon: Icon(LucideIcons.arrow_left, color: preset.textColor),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      key: const ValueKey('reader-header-book-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: preset.textColor,
                        fontSize: 16,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '正在阅读 · 第 $chapterNumber 章',
                      key: const ValueKey('reader-classic-chapter-label'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: preset.mutedTextColor,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              // Reserve at most half the row so a long book title still reads;
              // beyond that the actions scroll instead of shrinking to nothing.
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .52,
                ),
                child: SingleChildScrollView(
                  key: const ValueKey('reader-classic-toolbar-actions'),
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showCache)
                        _ClassicToolbarAction(
                          key: const ValueKey('reader-cache'),
                          icon: LucideIcons.download,
                          tooltip: '缓存',
                          preset: preset,
                          onPressed: onCache,
                        ),
                      if (showComments)
                        _ClassicToolbarAction(
                          key: const ValueKey(
                            'reader-toolbar-chapter-comments',
                          ),
                          icon: LucideIcons.message_circle,
                          tooltip: '本章评论',
                          preset: preset,
                          onPressed: onComments,
                        ),
                      _ClassicToolbarAction(
                        key: const ValueKey('reader-shelf-button'),
                        icon: inShelf
                            ? LucideIcons.bookmark_check
                            : LucideIcons.bookmark_plus,
                        tooltip: inShelf ? '已在书架' : '加入书架',
                        preset: preset,
                        onPressed: onShelf,
                      ),
                      _ClassicToolbarAction(
                        key: const ValueKey('reader-classic-collapse'),
                        icon: LucideIcons.chevron_up,
                        tooltip: '收起阅读菜单',
                        preset: preset,
                        onPressed: onCollapse,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ClassicToolbarAction extends StatelessWidget {
  const _ClassicToolbarAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.preset,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final ReaderThemePreset preset;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    iconSize: 20,
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 40, height: 40),
    icon: Icon(
      icon,
      color: onPressed == null ? preset.mutedTextColor : preset.textColor,
    ),
  );
}

/// Bottom chrome: the original one-piece top-rounded Material sheet.
///
/// Top down: the whole-book chapter picker (old semantics, commits on
/// release), the current chapter's internal progress (a different control with
/// its own key/semantics), then the old two action rows — 目录/查找/书签 above
/// 操作/AI/夜间/设置.
class ReaderClassicControls extends StatefulWidget {
  const ReaderClassicControls({
    super.key,
    required this.preset,
    required this.chapterIndex,
    required this.chapterCount,
    required this.chapterTitleAt,
    required this.fraction,
    required this.onPrevious,
    required this.onNext,
    required this.onSeekEnd,
    required this.onPreview,
    required this.onCommitted,
    required this.onPreviewChanged,
    required this.onDirectory,
    required this.onBookmarks,
    required this.onFind,
    required this.onNight,
    required this.onAppearance,
    required this.onOperations,
    this.onAi,
    this.aiLabel = 'AI 校对',
  });

  final ReaderThemePreset preset;
  final int chapterIndex;
  final int chapterCount;
  final String Function(int index) chapterTitleAt;

  /// Current chapter fraction, `null` until the chapter can be scrubbed.
  final double? fraction;

  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// Jump target of the whole-book picker; fired once, on release.
  final ValueChanged<int> onSeekEnd;

  final ValueChanged<double> onPreview;
  final ValueChanged<double> onCommitted;
  final ValueChanged<bool> onPreviewChanged;

  final VoidCallback onDirectory;
  final VoidCallback onBookmarks;
  final VoidCallback? onFind;
  final VoidCallback onNight;
  final VoidCallback onAppearance;
  final VoidCallback onOperations;
  final VoidCallback? onAi;
  final String aiLabel;

  @override
  State<ReaderClassicControls> createState() => _ReaderClassicControlsState();
}

class _ReaderClassicControlsState extends State<ReaderClassicControls> {
  /// Temporary picker position while the thumb is down. `null` = follow the
  /// page's current chapter. Nothing outside this widget changes until release.
  double? _seek;

  @override
  void didUpdateWidget(ReaderClassicControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The chapter changed underneath a drag (listening follow, directory, …):
    // drop the stale preview so the picker tracks the page again.
    if (_seek != null && oldWidget.chapterIndex != widget.chapterIndex) {
      _seek = null;
    }
  }

  double get _seekValue {
    final max = _seekMax;
    return (_seek ?? widget.chapterIndex.toDouble()).clamp(0.0, max);
  }

  double get _seekMax =>
      widget.chapterCount > 1 ? (widget.chapterCount - 1).toDouble() : 0;

  int get _seekIndex => widget.chapterCount <= 0
      ? 0
      : _seekValue.round().clamp(0, widget.chapterCount - 1);

  void _previewSeek(double value) => setState(() => _seek = value);

  void _commitSeek(double value) {
    final target = widget.chapterCount <= 0
        ? 0
        : value.round().clamp(0, widget.chapterCount - 1);
    setState(() => _seek = null);
    widget.onSeekEnd(target);
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: Material(
        key: const ValueKey('reader-classic-controls-panel'),
        color: preset.panelColor,
        surfaceTintColor: Colors.transparent,
        elevation: 16,
        shadowColor: Colors.black38,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: preset.isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
                width: 0.8,
              ),
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .62,
            ),
            child: SingleChildScrollView(
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _chapterSeek(preset),
                    const SizedBox(height: 4),
                    _chapterProgress(preset),
                    const SizedBox(height: 2),
                    _actions(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 整书章节选择：old reader's main slider. Dragging only moves this
  /// temporary index; the chapter is loaded once through [onSeekEnd].
  Widget _chapterSeek(ReaderThemePreset preset) {
    final count = widget.chapterCount;
    final enabled = count > 1;
    final index = _seekIndex;
    final value = _seekValue;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.chapterTitleAt(index),
                key: const ValueKey('reader-classic-seek-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: preset.textColor, fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${index + 1} / $count',
              key: const ValueKey('reader-classic-seek-position'),
              style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
            ),
          ],
        ),
        Row(
          children: [
            IconButton(
              key: const ValueKey('reader-classic-previous-chapter'),
              tooltip: '上一章',
              onPressed: widget.onPrevious,
              icon: const Icon(LucideIcons.skip_back, size: 20),
            ),
            Expanded(
              // 与章内进度分开的无障碍语义：整书选章，松开（或辅助功能增减）
              // 才真正换章。
              child: Semantics(
                key: const ValueKey('reader-classic-chapter-seek-semantics'),
                label: '整书选章',
                value: '第 ${index + 1} 章 / 共 $count 章',
                increasedValue:
                    '第 ${(index + 2).clamp(1, count)} 章 / 共 $count 章',
                decreasedValue: '第 ${index.clamp(1, count)} 章 / 共 $count 章',
                slider: true,
                enabled: enabled,
                onIncrease: enabled && index < count - 1
                    ? () => _commitSeek((_seekValue + 1).clamp(0, _seekMax))
                    : null,
                onDecrease: enabled && index > 0
                    ? () => _commitSeek((_seekValue - 1).clamp(0, _seekMax))
                    : null,
                child: ExcludeSemantics(
                  child: Slider(
                    key: const ValueKey('reader-chapter-seek'),
                    min: 0,
                    max: _seekMax,
                    value: value,
                    divisions: enabled ? count - 1 : null,
                    label: '第 ${index + 1} 章',
                    semanticFormatterCallback: (value) =>
                        '第 ${value.round() + 1} 章',
                    onChanged: enabled ? _previewSeek : null,
                    onChangeEnd: enabled ? _commitSeek : null,
                  ),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('reader-classic-next-chapter'),
              tooltip: '下一章',
              onPressed: widget.onNext,
              icon: const Icon(LucideIcons.skip_forward, size: 20),
            ),
          ],
        ),
      ],
    );
  }

  /// 本章进度：current chapter fraction, explicitly labelled so it can never be
  /// mistaken for the whole-book picker above. Reuses the archive control's
  /// preview/commit contract and semantics (`本章进度`).
  Widget _chapterProgress(ReaderThemePreset preset) {
    final fraction = widget.fraction;
    return ReaderValueSlider(
      sliderKey: const ValueKey('reader-classic-chapter-progress'),
      label: '本章进度',
      preset: preset,
      value: fraction ?? 0,
      min: 0,
      max: 1,
      divisions: 500,
      hapticSteps: 100,
      inline: true,
      format: (value) => '${(value * 100).round()}%',
      reconcileValue: true,
      onPreview: fraction == null ? null : widget.onPreview,
      onCommitted: fraction == null ? null : widget.onCommitted,
      onInteractionChanged: widget.onPreviewChanged,
    );
  }

  /// Two stable rows, as in the pre-#291 reader: content navigation first,
  /// then display/feature actions. No horizontal scroll, so each entry keeps a
  /// real touch target at 320dp; a short viewport scrolls the whole sheet
  /// vertically instead of hiding a button sideways.
  ///
  /// `操作` rides in the feature row: it is a fqapp-only entry the old shell did
  /// not have, and it must stay one tap away from 设置.
  Widget _actions() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        key: const ValueKey('reader-classic-nav-row'),
        children: [
          Expanded(
            child: _ClassicAction(
              key: const ValueKey('reader-catalogue-entry'),
              icon: LucideIcons.book_open,
              label: '目录',
              onTap: widget.onDirectory,
            ),
          ),
          Expanded(
            child: _ClassicAction(
              key: const ValueKey('reader-find-entry'),
              icon: LucideIcons.search,
              label: '查找',
              onTap: widget.onFind,
            ),
          ),
          Expanded(
            child: _ClassicAction(
              key: const ValueKey('reader-bookmarks-entry'),
              icon: LucideIcons.bookmark,
              label: '书签',
              onTap: widget.onBookmarks,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Row(
        key: const ValueKey('reader-classic-feature-row'),
        children: [
          Expanded(
            child: _ClassicAction(
              key: const ValueKey('reader-operations-entry'),
              icon: LucideIcons.sliders_horizontal,
              label: '操作',
              onTap: widget.onOperations,
            ),
          ),
          if (widget.onAi != null)
            Expanded(
              child: _ClassicAction(
                key: const ValueKey('reader-ai'),
                icon: LucideIcons.sparkles,
                label: widget.aiLabel,
                onTap: widget.onAi,
              ),
            ),
          Expanded(
            child: _ClassicAction(
              key: const ValueKey('reader-night-entry'),
              icon: widget.preset.isDark ? LucideIcons.sun : LucideIcons.moon,
              label: widget.preset.isDark ? '日间' : '夜间',
              onTap: widget.onNight,
            ),
          ),
          Expanded(
            child: _ClassicAction(
              key: const ValueKey('reader-settings'),
              icon: LucideIcons.sliders_horizontal,
              label: '设置',
              onTap: widget.onAppearance,
            ),
          ),
        ],
      ),
    ],
  );
}

class _ClassicAction extends StatelessWidget {
  const _ClassicAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: label,
    child: TextButton(
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    ),
  );
}
