// Classic reader chrome. Chapter scrubbing only previews locally; the reader
// loads and persists the target once, on release.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

class ReaderClassicToolbar extends StatelessWidget {
  const ReaderClassicToolbar({
    super.key,
    required this.preset,
    required this.showCache,
    required this.showComments,
    required this.inShelf,
    required this.onBack,
    required this.onCache,
    required this.onComments,
    required this.onShelf,
    required this.onShare,
    required this.onMore,
  });

  final ReaderThemePreset preset;
  final bool showCache;
  final bool showComments;
  final bool inShelf;
  final VoidCallback onBack;
  final VoidCallback onCache;
  final VoidCallback onComments;
  final VoidCallback onShelf;
  final VoidCallback? onShare;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('reader-classic-toolbar'),
    color: preset.panelColor,
    surfaceTintColor: Colors.transparent,
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: LayoutBuilder(
          builder: (context, bounds) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: math.max(bounds.maxWidth, 352),
              child: Row(
                children: [
                  _action(
                    'reader-back-entry',
                    LucideIcons.arrow_left,
                    '返回书籍',
                    onBack,
                  ),
                  Expanded(
                    child: TextButton(
                      key: const ValueKey('reader-shelf-button'),
                      onPressed: onShelf,
                      style: TextButton.styleFrom(
                        foregroundColor: preset.textColor,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        minimumSize: const Size(48, 48),
                      ),
                      child: Text(
                        inShelf ? '已加书架' : '加入书架',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  if (showCache)
                    _action(
                      'reader-cache',
                      LucideIcons.download,
                      '缓存',
                      onCache,
                    ),
                  if (showComments)
                    _action(
                      'reader-toolbar-chapter-comments',
                      LucideIcons.message_circle,
                      '本章评论',
                      onComments,
                    ),
                  if (onShare != null)
                    _action(
                      'reader-share',
                      LucideIcons.share,
                      '分享书籍链接',
                      onShare,
                    ),
                  _action(
                    'reader-classic-more',
                    LucideIcons.ellipsis_vertical,
                    '更多阅读操作',
                    onMore,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _action(
    String key,
    IconData icon,
    String label,
    VoidCallback? onTap,
  ) => IconButton(
    key: ValueKey(key),
    tooltip: label,
    onPressed: onTap,
    constraints: const BoxConstraints.tightFor(width: 48, height: 48),
    icon: Icon(
      icon,
      size: 24,
      color: onTap == null ? preset.mutedTextColor : preset.textColor,
    ),
  );
}

class ReaderClassicControls extends StatefulWidget {
  const ReaderClassicControls({
    super.key,
    required this.preset,
    required this.chapterIndex,
    required this.chapterCount,
    required this.chapterTitleAt,
    required this.onPrevious,
    required this.onNext,
    required this.onSeekEnd,
    required this.onDirectory,
    required this.onNight,
    required this.onAppearance,
    this.onAi,
    this.aiLabel = 'AI 校对',
  });

  final ReaderThemePreset preset;
  final int chapterIndex;
  final int chapterCount;
  final String Function(int index) chapterTitleAt;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final ValueChanged<int> onSeekEnd;
  final VoidCallback onDirectory;
  final VoidCallback onNight;
  final VoidCallback onAppearance;
  final VoidCallback? onAi;
  final String aiLabel;

  @override
  State<ReaderClassicControls> createState() => _ReaderClassicControlsState();
}

class _ReaderClassicControlsState extends State<ReaderClassicControls> {
  double? _seek;
  final _bubble = OverlayPortalController();
  final _bubbleLink = LayerLink();

  @override
  void didUpdateWidget(ReaderClassicControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_seek != null &&
        (oldWidget.chapterIndex != widget.chapterIndex ||
            oldWidget.chapterCount != widget.chapterCount)) {
      _seek = null;
      _bubble.hide();
    }
  }

  double get _seekMax => math.max(0, widget.chapterCount - 1).toDouble();
  double get _seekValue =>
      (_seek ?? widget.chapterIndex.toDouble()).clamp(0, _seekMax);
  int get _seekIndex => _seekValue.round();

  void _commitSeek(double value) {
    final target = value.round().clamp(0, _seekMax.toInt());
    _bubble.hide();
    setState(() => _seek = null);
    widget.onSeekEnd(target);
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: OverlayPortal(
        controller: _bubble,
        overlayChildBuilder: (context) => Positioned(
          width: math.min(280, MediaQuery.sizeOf(context).width - 48),
          child: CompositedTransformFollower(
            link: _bubbleLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topCenter,
            followerAnchor: Alignment.bottomCenter,
            offset: const Offset(0, -12),
            child: IgnorePointer(
              child: Material(
                key: const ValueKey('reader-classic-seek-preview'),
                color: preset.textColor.withValues(alpha: .86),
                borderRadius: BorderRadius.circular(40),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Text(
                    '${widget.chapterCount <= 1 ? 0 : (_seekValue / _seekMax * 100).round()}%\n${widget.chapterCount == 0 ? '' : widget.chapterTitleAt(_seekIndex)}',
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: preset.backgroundColor,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        child: CompositedTransformTarget(
          link: _bubbleLink,
          child: Material(
            key: const ValueKey('reader-classic-controls-panel'),
            color: preset.panelColor,
            surfaceTintColor: Colors.transparent,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .62,
              ),
              child: SingleChildScrollView(
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _chapterSeek(preset),
                      const SizedBox(height: 8),
                      _actions(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chapterSeek(ReaderThemePreset preset) {
    final count = widget.chapterCount;
    final enabled = count > 1;
    final index = _seekIndex;
    return Row(
      children: [
        TextButton(
          key: const ValueKey('reader-classic-previous-chapter'),
          onPressed: widget.onPrevious,
          style: TextButton.styleFrom(
            foregroundColor: preset.textColor,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(48, 48),
          ),
          child: const Text('上一章'),
        ),
        Expanded(
          child: Semantics(
            key: const ValueKey('reader-classic-chapter-seek-semantics'),
            label: '整书选章',
            value: count == 0 ? '没有章节' : '第 ${index + 1} 章 / 共 $count 章',
            increasedValue: count == 0
                ? null
                : '第 ${(index + 2).clamp(1, count)} 章 / 共 $count 章',
            decreasedValue: count == 0
                ? null
                : '第 ${index.clamp(1, count)} 章 / 共 $count 章',
            slider: true,
            enabled: enabled,
            onIncrease: enabled && index < count - 1
                ? () => _commitSeek(_seekValue + 1)
                : null,
            onDecrease: enabled && index > 0
                ? () => _commitSeek(_seekValue - 1)
                : null,
            child: ExcludeSemantics(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 20,
                  activeTrackColor: preset.mutedTextColor.withValues(
                    alpha: .25,
                  ),
                  inactiveTrackColor: preset.mutedTextColor.withValues(
                    alpha: .08,
                  ),
                  thumbColor: preset.panelColor,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 12,
                    elevation: 3,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 18,
                  ),
                  showValueIndicator: ShowValueIndicator.never,
                  trackShape: const RoundedRectSliderTrackShape(),
                ),
                child: Slider(
                  key: const ValueKey('reader-chapter-seek'),
                  min: 0,
                  max: _seekMax,
                  value: _seekValue,
                  onChangeStart: enabled
                      ? (value) {
                          setState(() => _seek = value);
                          _bubble.show();
                        }
                      : null,
                  onChanged: enabled
                      ? (value) => setState(() => _seek = value)
                      : null,
                  onChangeEnd: enabled ? _commitSeek : null,
                ),
              ),
            ),
          ),
        ),
        TextButton(
          key: const ValueKey('reader-classic-next-chapter'),
          onPressed: widget.onNext,
          style: TextButton.styleFrom(
            foregroundColor: preset.textColor,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(48, 48),
          ),
          child: const Text('下一章'),
        ),
      ],
    );
  }

  Widget _actions() => Row(
    key: const ValueKey('reader-classic-action-row'),
    children: [
      Expanded(
        child: _ClassicAction(
          key: const ValueKey('reader-catalogue-entry'),
          icon: LucideIcons.book_open,
          label: '目录',
          onTap: widget.onDirectory,
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
  Widget build(BuildContext context) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      minimumSize: const Size(48, 64),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 24),
        const SizedBox(height: 8),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
}
