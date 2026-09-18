import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// Official-shape reading menu: a slim bottom bar of 目录 / 夜间 / 听书 / 设置.
/// Brightness, chapter seek and the secondary actions live behind 设置 so the
/// bar itself stays short.
class ReaderControls extends StatefulWidget {
  final ReaderPreferences preferences;
  final int chapterIndex;
  final int chapterCount;
  final String chapterTitle;
  final double seekValue;
  final bool deviceAvailable;
  final double? systemBrightness;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final ValueChanged<double> onSeek;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<double> onBrightness;
  final VoidCallback onBrightnessEnd;
  final VoidCallback onFollowSystem;
  final VoidCallback onDirectory;
  final VoidCallback onNight;
  final VoidCallback onAppearance;
  final VoidCallback onCache;

  /// 听书: opens the listening page for this book.
  final VoidCallback onListen;

  final bool autoTurnActive;
  final VoidCallback onAutoTurn;

  const ReaderControls({
    super.key,
    required this.preferences,
    required this.chapterIndex,
    required this.chapterCount,
    required this.chapterTitle,
    required this.seekValue,
    required this.deviceAvailable,
    required this.systemBrightness,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onSeekEnd,
    required this.onBrightness,
    required this.onBrightnessEnd,
    required this.onFollowSystem,
    required this.onDirectory,
    required this.onNight,
    required this.onAppearance,
    required this.onCache,
    required this.onListen,
    this.autoTurnActive = false,
    required this.onAutoTurn,
  });

  @override
  State<ReaderControls> createState() => _ReaderControlsState();
}

class _ReaderControlsState extends State<ReaderControls> {
  bool _settingsOpen = false;

  @override
  Widget build(BuildContext context) {
    final preset = widget.preferences.themePreset;
    final level = widget.preferences.followSystemBrightness
        ? widget.systemBrightness ?? widget.preferences.brightness
        : widget.preferences.brightness;
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: Material(
        color: preset.panelColor,
        elevation: 12,
        shadowColor: Colors.black26,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.62,
          ),
          child: SingleChildScrollView(
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_settingsOpen) ...[
                    _chapterSeek(preset),
                    if (widget.deviceAvailable) _brightness(preset, level),
                    _extraActions(preset),
                    const SizedBox(height: 4),
                  ],
                  Row(
                    children: [
                      _Action(
                        icon: Icons.menu_book_outlined,
                        label: '目录',
                        onTap: widget.onDirectory,
                      ),
                      _Action(
                        icon: preset.isDark
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        label: preset.isDark ? '日间' : '夜间',
                        onTap: widget.onNight,
                      ),
                      _Action(
                        icon: Icons.headphones_outlined,
                        label: '听书',
                        onTap: widget.onListen,
                      ),
                      _Action(
                        key: const ValueKey('reader-settings'),
                        icon: Icons.settings_outlined,
                        label: '设置',
                        selected: _settingsOpen,
                        onTap: () =>
                            setState(() => _settingsOpen = !_settingsOpen),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chapterSeek(ReaderThemePreset preset) {
    final max = (widget.chapterCount - 1).toDouble();
    final upper = max < 0 ? 0.0 : max;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: preset.textColor, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.chapterIndex + 1} / ${widget.chapterCount}',
                style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: '上一章',
                onPressed: widget.onPrevious,
                icon: const Icon(Icons.skip_previous_rounded, size: 22),
              ),
              Expanded(
                child: Slider(
                  key: const ValueKey('reader-chapter-seek'),
                  min: 0,
                  max: upper,
                  value: widget.seekValue.clamp(0, upper),
                  onChanged: widget.chapterCount > 1 ? widget.onSeek : null,
                  onChangeEnd: widget.chapterCount > 1
                      ? widget.onSeekEnd
                      : null,
                  semanticFormatterCallback: (value) =>
                      '第 ${value.round() + 1} 章',
                ),
              ),
              IconButton(
                tooltip: '下一章',
                onPressed: widget.onNext,
                icon: const Icon(Icons.skip_next_rounded, size: 22),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _brightness(ReaderThemePreset preset, double level) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Icon(
              Icons.brightness_6_outlined,
              size: 20,
              color: preset.mutedTextColor,
            ),
          ),
          Expanded(
            child: Slider(
              key: const ValueKey('reader-brightness'),
              value: level.clamp(0.02, 1),
              min: 0.02,
              max: 1,
              onChanged: widget.onBrightness,
              onChangeEnd: (_) => widget.onBrightnessEnd(),
              semanticFormatterCallback: (value) =>
                  '亮度 ${(value * 100).round()}%',
            ),
          ),
          Semantics(
            toggled: widget.preferences.followSystemBrightness,
            child: TextButton(
              key: const ValueKey('reader-follow-system'),
              style: TextButton.styleFrom(
                foregroundColor: widget.preferences.followSystemBrightness
                    ? preset.accentColor
                    : preset.mutedTextColor,
                backgroundColor: widget.preferences.followSystemBrightness
                    ? preset.accentColor.withValues(alpha: 0.09)
                    : null,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: widget.onFollowSystem,
              child: const Text('跟随系统', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _extraActions(ReaderThemePreset preset) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  key: const ValueKey('reader-auto-turn'),
                  style: TextButton.styleFrom(
                    foregroundColor: widget.autoTurnActive
                        ? preset.accentColor
                        : preset.textColor,
                  ),
                  onPressed: widget.onAutoTurn,
                  icon: Icon(
                    widget.autoTurnActive
                        ? Icons.pause_circle_outline_rounded
                        : Icons.play_circle_outline_rounded,
                    size: 18,
                  ),
                  label: Text(
                    widget.autoTurnActive ? '停止自动翻页' : '自动翻页',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              _Action(
                icon: Icons.download_for_offline_outlined,
                label: '缓存',
                onTap: widget.onCache,
              ),
              _Action(
                icon: Icons.text_fields_rounded,
                label: '排版',
                onTap: widget.onAppearance,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  const _Action({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurface;
    return Expanded(
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
