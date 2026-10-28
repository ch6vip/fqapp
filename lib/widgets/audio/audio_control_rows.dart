import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/audio_page_theme.dart';
import '../../services/playback_format.dart';
import '../home/home_design.dart';

class AudioIconRow extends StatelessWidget {
  final List<AudioIconAction> actions;

  const AudioIconRow({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return Row(
      children: [
        for (final action in actions)
          Expanded(
            child: HomePressable(
              key: ValueKey(action.key),
              semanticLabel: action.semanticLabel ?? action.label,
              onTap: action.onTap ?? () {},
              onLongPress: action.onLongPress,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(action.icon, size: 24, color: theme.ink),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            action.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: action.active
                                  ? theme.accent
                                  : theme.muted,
                              fontSize: 12,
                              height: 1.25,
                            ),
                          ),
                        ),
                        if (action.badgeIcon case final badge?) ...[
                          const SizedBox(width: 3),
                          Icon(badge, size: 12, color: theme.accent),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class AudioIconAction {
  const AudioIconAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.semanticLabel,
    this.active = false,
    this.badgeIcon,
  });

  final String key;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// 长按动作：倍速项用它做「锁定倍速」（官方 `a4g`）。
  final VoidCallback? onLongPress;
  final String? semanticLabel;
  final bool active;

  /// 标签旁的小徽标（例如倍速锁定时的锁图标）。
  final IconData? badgeIcon;
}

/// `layout/bjg.xml` + `AudioLabelSeekBar`：`-15 s` / 轨道 / 时间药丸 / `+15 s`。
///
/// 官方在轨道的播放头位置挂一枚深色药丸显示 `08:01/11:40`（截图 2.jpg），

class AudioTimeSeekRow extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final double? preview;
  final bool enabled;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final VoidCallback? onBack15;
  final VoidCallback? onForward15;

  const AudioTimeSeekRow({
    super.key,
    required this.position,
    required this.duration,
    this.preview,
    this.enabled = true,
    this.onChanged,
    this.onChangeEnd,
    this.onBack15,
    this.onForward15,
  });

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    final maximum = duration.inMilliseconds.toDouble();
    final value = (preview ?? position.inMilliseconds.toDouble()).clamp(
      0.0,
      maximum > 0 ? maximum : 1.0,
    );
    final active = enabled && maximum > 0;
    return Row(
      children: [
        _SkipLabel(text: '-15 s', onTap: onBack15, theme: theme),
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.5,
                  activeTrackColor: theme.accent,
                  inactiveTrackColor: theme.line,
                  thumbColor: theme.accent,
                  // 官方把播放头画成药丸，滑块本身不可见。
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 0,
                    disabledThumbRadius: 0,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  key: const ValueKey('audio-seek'),
                  value: value,
                  max: maximum > 0 ? maximum : 1,
                  label: _time(value),
                  onChanged: active ? onChanged : null,
                  onChangeEnd: active ? onChangeEnd : null,
                ),
              ),
              // 药丸压在滑轨上、跟着进度走。IgnorePointer 保证拖拽仍然落在 Slider。
              IgnorePointer(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final max = maximum > 0 ? maximum : 1.0;
                    final ratio = (value / max).clamp(0.0, 1.0);
                    final pillWidth = math.min(
                      112.0,
                      constraints.maxWidth * 0.4,
                    );
                    // Align 自身会把子项宽度算进可用行程，所以 -1..1 正好
                    // 覆盖「左端贴边 → 右端贴边」，不用另算 travel。
                    return Align(
                      alignment: Alignment(math.min(1.0, ratio) * 2 - 1, 0),
                      child: SizedBox(
                        width: pillWidth,
                        height: 24,
                        child: Center(
                          child: _TimePill(
                            text:
                                '${_time(value)}/${_time(maximum.toInt().toDouble())}',
                            theme: theme,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        _SkipLabel(text: '+15 s', onTap: onForward15, theme: theme),
      ],
    );
  }

  static String _time(double ms) =>
      formatPlaybackTime(Duration(milliseconds: ms.round()));
}

class _SkipLabel extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  final AudioPageTheme theme;

  const _SkipLabel({required this.text, this.onTap, required this.theme});

  @override
  Widget build(BuildContext context) {
    return HomePressable(
      semanticLabel: text.replaceAll(' ', ''),
      onTap: onTap ?? () {},
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Text(
          text,
          style: TextStyle(
            color: onTap == null ? theme.line : theme.muted,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _TimePill extends StatelessWidget {
  final String text;
  final AudioPageTheme theme;

  const _TimePill({required this.text, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('audio-time-pill'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.ink,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          color: theme.canvas,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
      ),
    );
  }
}

/// `layout/bin.xml`：目录 / 上一章 / 播放(60dp) / 下一章 / 定时。
///
/// 第 5 个槽位在官方是**悬浮的橙色圆钮**（截图 2.jpg 右侧，带一个 ×），不是

class AudioTransportRow extends StatelessWidget {
  final VoidCallback? onCatalog;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onPlayPause;
  final VoidCallback? onSleepTimer;
  final bool playing;
  final bool loading;
  final bool ready;
  final String? sleepLabel;

  const AudioTransportRow({
    super.key,
    this.onCatalog,
    this.onPrevious,
    this.onNext,
    this.onPlayPause,
    this.onSleepTimer,
    this.playing = false,
    this.loading = false,
    this.ready = false,
    this.sleepLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = ((constraints.maxWidth - 252) / 3).clamp(8.0, 40.0);
        return Row(
          children: [
            _LabeledIcon(
              icon: LucideIcons.list,
              label: '目录',
              onTap: onCatalog,
              theme: theme,
            ),
            const Spacer(),
            _BareIcon(
              icon: LucideIcons.skip_back,
              tooltip: '上一章',
              onTap: onPrevious,
              theme: theme,
            ),
            SizedBox(width: gap),
            Semantics(
              button: true,
              child: SizedBox(
                key: const Key('audio_play'),
                width: 60,
                height: 60,
                child: IconButton(
                  tooltip: playing ? '暂停' : '播放',
                  onPressed: ready ? onPlayPause : null,
                  padding: EdgeInsets.zero,
                  iconSize: 40,
                  style: IconButton.styleFrom(
                    foregroundColor: theme.ink,
                    disabledForegroundColor: theme.muted.withValues(alpha: 0.5),
                  ),
                  icon: loading && !playing
                      ? SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.accent,
                          ),
                        )
                      : Icon(playing ? LucideIcons.pause : LucideIcons.play),
                ),
              ),
            ),
            SizedBox(width: gap),
            _BareIcon(
              icon: LucideIcons.skip_forward,
              tooltip: '下一章',
              onTap: onNext,
              theme: theme,
            ),
            const Spacer(),
            // 官方 `bin.xml` 的 `i58`：与左侧「目录」(`axr`) 同构的
            // 24dp 图标 + 12sp 文字。截图里那颗橙色圆钮是广告浮层，不是定时。
            _LabeledIcon(
              key: const Key('audio_sleep'),
              icon: LucideIcons.timer,
              label: sleepLabel ?? '定时',
              onTap: onSleepTimer,
              theme: theme,
              active: sleepLabel != null,
            ),
          ],
        );
      },
    );
  }
}

class _BareIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final AudioPageTheme theme;

  const _BareIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    visualDensity: VisualDensity.compact,
    iconSize: 24,
    style: IconButton.styleFrom(
      foregroundColor: theme.ink,
      disabledForegroundColor: theme.line,
    ),
    icon: Icon(icon),
  );
}

class _LabeledIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final AudioPageTheme theme;

  /// 激活态（例如定时已开启）用强调色。
  final bool active;

  const _LabeledIcon({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.theme,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    // 保留 tooltip：官方是 `bin.xml` 里图标 + 12sp 文案的组合，而我们仓库
    // 一直有「按 tooltip 找目录键」的测试/无障碍契约。
    return Tooltip(
      message: label,
      child: HomePressable(
        semanticLabel: label,
        onTap: onTap ?? () {},
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          // 官方 minWidth 48dp。这里保持 56：`AudioTransportRow` 的 gap 公式
          // 把 252(=56+40+60+40+56) 当固定宽度算，改成 64 会在 320dp 窄屏
          // 溢出 6.7px。「剩余本章」四个汉字 12sp 约 48dp，装得下。
          width: 56,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: active ? theme.accent : theme.ink),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: active ? theme.accent : theme.muted,
                  fontSize: 12,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// 官方封面卡的整体：12dp 圆角、正方形封面、底部渐变 + 两行页脚，
