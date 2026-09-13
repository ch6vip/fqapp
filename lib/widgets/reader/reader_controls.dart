import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

class ReaderControls extends StatelessWidget {
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

  /// 自动翻页 toggle and the chapter-comment entry (章末章评). The comment
  /// action is null while the chapter has no ideas.
  final bool autoTurnActive;
  final VoidCallback onAutoTurn;

  /// 边走边读: system-TTS narration inside the reader.
  final bool ttsActive;
  final VoidCallback onTtsRead;

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
    this.autoTurnActive = false,
    required this.onAutoTurn,
    this.ttsActive = false,
    required this.onTtsRead,
  });

  @override
  Widget build(BuildContext context) {
    final preset = preferences.themePreset;
    final level = preferences.followSystemBrightness
        ? systemBrightness ?? preferences.brightness
        : preferences.brightness;
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: Material(
        color: preset.panelColor,
        elevation: 12,
        shadowColor: Colors.black26,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.65,
          ),
          child: SingleChildScrollView(
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: preset.textColor,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${chapterIndex + 1} / $chapterCount',
                        style: TextStyle(
                          color: preset.mutedTextColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: '上一章',
                        onPressed: onPrevious,
                        icon: const Icon(Icons.skip_previous_rounded, size: 23),
                      ),
                      Expanded(
                        child: Slider(
                          key: const ValueKey('reader-chapter-seek'),
                          min: 0,
                          max: (chapterCount - 1).toDouble(),
                          value: seekValue.clamp(
                            0,
                            (chapterCount - 1).toDouble(),
                          ),
                          onChanged: chapterCount > 1 ? onSeek : null,
                          onChangeEnd: chapterCount > 1 ? onSeekEnd : null,
                          semanticFormatterCallback: (value) =>
                              '第 ${value.round() + 1} 章',
                        ),
                      ),
                      IconButton(
                        tooltip: '下一章',
                        onPressed: onNext,
                        icon: const Icon(Icons.skip_next_rounded, size: 23),
                      ),
                    ],
                  ),
                  if (deviceAvailable) ...[
                    Divider(height: 8, color: preset.borderColor),
                    Row(
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
                            onChanged: onBrightness,
                            onChangeEnd: (_) => onBrightnessEnd(),
                            semanticFormatterCallback: (value) =>
                                '亮度 ${(value * 100).round()}%',
                          ),
                        ),
                        Semantics(
                          toggled: preferences.followSystemBrightness,
                          child: TextButton(
                            key: const ValueKey('reader-follow-system'),
                            style: TextButton.styleFrom(
                              foregroundColor:
                                  preferences.followSystemBrightness
                                  ? preset.accentColor
                                  : preset.mutedTextColor,
                              backgroundColor:
                                  preferences.followSystemBrightness
                                  ? preset.accentColor.withValues(alpha: 0.09)
                                  : null,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                            ),
                            onPressed: onFollowSystem,
                            child: const Text(
                              '跟随系统',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _Action(
                        icon: Icons.menu_book_outlined,
                        label: '目录',
                        onTap: onDirectory,
                      ),
                      _Action(
                        icon: preset.isDark
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        label: preset.isDark ? '日间' : '夜间',
                        onTap: onNight,
                      ),
                      _Action(
                        icon: Icons.text_fields_rounded,
                        label: '排版',
                        onTap: onAppearance,
                      ),
                      _Action(
                        icon: Icons.download_for_offline_outlined,
                        label: '缓存',
                        onTap: onCache,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          key: const ValueKey('reader-auto-turn'),
                          style: TextButton.styleFrom(
                            foregroundColor: autoTurnActive
                                ? preset.accentColor
                                : preset.textColor,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: onAutoTurn,
                          icon: Icon(
                            autoTurnActive
                                ? Icons.pause_circle_outline_rounded
                                : Icons.play_circle_outline_rounded,
                            size: 19,
                          ),
                          label: Text(
                            autoTurnActive ? '停止自动翻页' : '自动翻页',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          key: const ValueKey('reader-tts-read'),
                          style: TextButton.styleFrom(
                            foregroundColor: ttsActive
                                ? preset.accentColor
                                : preset.textColor,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: onTtsRead,
                          icon: Icon(
                            ttsActive
                                ? Icons.pause_circle_outline_rounded
                                : Icons.record_voice_over_outlined,
                            size: 19,
                          ),
                          label: Text(
                            ttsActive ? '停止朗读' : '边走边读',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Ideas get their own row so the count badge has room and the
                  // four primary actions keep their size.
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _Action({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
    child: TextButton(
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 23),
          const SizedBox(height: 7),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );
}
