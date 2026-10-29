import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// Reading menu. 章节进度行始终显示，下面只有四个主操作：目录 / 夜间 /
/// 听书 / 设置；排版项由 设置 直接打开阅读设置面板。
class ReaderControls extends StatelessWidget {
  final ReaderPreferences preferences;
  final int chapterIndex;
  final int chapterCount;
  final String chapterTitle;
  final double seekValue;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final ValueChanged<double> onSeek;
  final ValueChanged<double> onSeekEnd;
  final VoidCallback onDirectory;
  final VoidCallback onNight;
  final VoidCallback onAppearance;

  /// 听书: opens the listening page for this book.
  final VoidCallback onListen;
  final bool showListening;

  const ReaderControls({
    super.key,
    required this.preferences,
    required this.chapterIndex,
    required this.chapterCount,
    required this.chapterTitle,
    required this.seekValue,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onSeekEnd,
    required this.onDirectory,
    required this.onNight,
    required this.onAppearance,
    required this.onListen,
    this.showListening = true,
  });

  @override
  Widget build(BuildContext context) {
    final preset = preferences.themePreset;
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: Material(
        color: preset.panelColor,
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
              maxHeight: MediaQuery.sizeOf(context).height * 0.62,
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
                    Row(
                      children: [
                        _Action(
                          icon: LucideIcons.book_open,
                          label: '目录',
                          onTap: onDirectory,
                        ),
                        _Action(
                          icon: preset.isDark
                              ? LucideIcons.sun
                              : LucideIcons.moon,
                          label: preset.isDark ? '日间' : '夜间',
                          onTap: onNight,
                        ),
                        if (showListening)
                          _Action(
                            icon: LucideIcons.headphones,
                            label: '听书',
                            onTap: onListen,
                          ),
                        _Action(
                          key: const ValueKey('reader-settings'),
                          icon: LucideIcons.sliders_horizontal,
                          label: '设置',
                          onTap: onAppearance,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chapterSeek(ReaderThemePreset preset) {
    final max = (chapterCount - 1).toDouble();
    final upper = max < 0 ? 0.0 : max;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: preset.textColor, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${chapterIndex + 1} / $chapterCount',
                style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: '上一章',
                onPressed: onPrevious,
                icon: const Icon(LucideIcons.skip_back, size: 20),
              ),
              Expanded(
                child: Slider(
                  key: const ValueKey('reader-chapter-seek'),
                  min: 0,
                  max: upper,
                  value: seekValue.clamp(0, upper),
                  onChanged: chapterCount > 1 ? onSeek : null,
                  onChangeEnd: chapterCount > 1 ? onSeekEnd : null,
                  semanticFormatterCallback: (value) =>
                      '第 ${value.round() + 1} 章',
                ),
              ),
              IconButton(
                tooltip: '下一章',
                onPressed: onNext,
                icon: const Icon(LucideIcons.skip_forward, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 阅读页顶栏的缓存入口：分成阅读菜单后，缓存不再占底部一行。
class ReaderCacheButton extends StatelessWidget {
  const ReaderCacheButton({
    super.key,
    required this.preset,
    required this.onTap,
  });

  final ReaderThemePreset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('reader-cache'),
    tooltip: '缓存',
    onPressed: onTap,
    icon: Icon(LucideIcons.download, color: preset.textColor),
  );
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _Action({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurface,
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
