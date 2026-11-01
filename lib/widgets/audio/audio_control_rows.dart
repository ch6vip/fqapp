import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/audio_page_theme.dart';
import '../../services/audio_time_format.dart';
import '../../services/playback_format.dart';
import '../home/home_design.dart';

class AudioIconRow extends StatelessWidget {
  final List<AudioIconAction> actions;

  /// 真人讲书模式（样稿 `.acts`）：图标与文字间距 6dp，条目本身不再留
  /// 上下空白，整个操作行的 `8/8/8/0` 外边距由页面给出。
  final bool real;

  const AudioIconRow({super.key, required this.actions, this.real = false});

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
                padding: EdgeInsets.symmetric(vertical: real ? 0 : 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(action.icon, size: 24, color: theme.ink),
                    SizedBox(height: real ? 6 : 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            action.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: action.active ? theme.accent : theme.muted,
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
  /// 真人讲书模式的行高（样稿 `.seek { height: 44px }`）。
  static const realHeight = 44.0;

  /// 真人模式时间药丸：高 18dp、圆角 4dp、10.5sp、左右 6dp 内边距。
  static const realPillHeight = 18.0;
  static const realPillRadius = 4.0;
  static const realPillFontSize = 10.5;
  static const realPillPadding = 6.0;

  final Duration position;
  final Duration duration;
  final double? preview;
  final bool enabled;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final VoidCallback? onBack15;
  final VoidCallback? onForward15;

  /// 真人讲书模式（样稿 `.seek`）：44dp 行高、12sp ink 跳转文字、2dp 轨道、
  /// 18dp accent 药丸，药丸按播放头居中后再夹在轨道两端。
  final bool real;

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
    this.real = false,
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
    final row = Row(
      children: [
        _SkipLabel(text: '-15 s', onTap: onBack15, theme: theme, real: real),
        Expanded(child: _buildTrack(context, theme, value, maximum, active)),
        _SkipLabel(text: '+15 s', onTap: onForward15, theme: theme, real: real),
      ],
    );
    return real ? SizedBox(height: realHeight, child: row) : row;
  }

  Widget _buildTrack(
    BuildContext context,
    AudioPageTheme theme,
    double value,
    double maximum,
    bool active,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final max = maximum > 0 ? maximum : 1.0;
        final ratio = (value / max).clamp(0.0, 1.0);
        return Stack(
          alignment: Alignment.center,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: real ? 2 : 2.5,
                activeTrackColor: theme.accent,
                inactiveTrackColor: theme.line,
                thumbColor: theme.accent,
                // 官方把播放头画成药丸，滑块本身不可见。
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 0,
                  disabledThumbRadius: 0,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                key: const ValueKey('audio-seek'),
                value: value,
                max: maximum > 0 ? maximum : 1,
                label: real
                    ? formatAudioProgress(
                        Duration(milliseconds: value.round()),
                        duration,
                      )
                    : _time(value),
                onChanged: active ? onChanged : null,
                onChangeEnd: active ? onChangeEnd : null,
              ),
            ),
            // 药丸压在滑轨上、跟着进度走。IgnorePointer 保证拖拽仍然落在 Slider。
            if (real)
              _realPill(context, theme, ratio, width, value)
            else
              IgnorePointer(
                child: _legacyPill(theme, ratio, width, value, maximum),
              ),
          ],
        );
      },
    );
  }

  /// 样稿：药丸中心对准播放头，左右两侧再夹回轨道内。
  Widget _realPill(
    BuildContext context,
    AudioPageTheme theme,
    double ratio,
    double width,
    double value,
  ) {
    final text = formatAudioProgress(
      Duration(milliseconds: value.round()),
      duration,
    );
    final pillWidth = _measurePillWidth(context, text);
    final left = (ratio * width - pillWidth / 2)
        .clamp(0.0, math.max(0.0, width - pillWidth))
        .toDouble();
    return Positioned(
      left: left,
      top: (realHeight - realPillHeight) / 2,
      child: IgnorePointer(
        child: _TimePill(text: text, theme: theme, real: true),
      ),
    );
  }

  /// 智能朗读沿用旧行为：药丸宽度按轨道 40% 取档、两端按比例对齐。
  Widget _legacyPill(
    AudioPageTheme theme,
    double ratio,
    double width,
    double value,
    double maximum,
  ) {
    final pillWidth = math.min(112.0, width * 0.4);
    // Align 自身会把子项宽度算进可用行程，所以 -1..1 正好
    // 覆盖「左端贴边 → 右端贴边」，不用另算 travel。
    return Align(
      alignment: Alignment(math.min(1.0, ratio) * 2 - 1, 0),
      child: SizedBox(
        width: pillWidth,
        height: 24,
        child: Center(
          child: _TimePill(
            text: '${_time(value)}/${_time(maximum.toInt().toDouble())}',
            theme: theme,
          ),
        ),
      ),
    );
  }

  static double _measurePillWidth(BuildContext context, String text) {
    // Text 会把显式样式合到 DefaultTextStyle 上（Material 3 的默认字体会带
    // letterSpacing），这里用同一份合并结果量宽，否则药丸会偏离播放头。
    final style = DefaultTextStyle.of(
      context,
    ).style.merge(_TimePill.realTextStyle);
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width + realPillPadding * 2;
    painter.dispose();
    return width;
  }

  static String _time(double ms) =>
      formatPlaybackTime(Duration(milliseconds: ms.round()));
}

class _SkipLabel extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  final AudioPageTheme theme;
  final bool real;

  const _SkipLabel({
    required this.text,
    this.onTap,
    required this.theme,
    this.real = false,
  });

  @override
  Widget build(BuildContext context) {
    return HomePressable(
      semanticLabel: text.replaceAll(' ', ''),
      onTap: onTap ?? () {},
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: real ? 0 : 8, vertical: 10),
        child: Text(
          text,
          style: TextStyle(
            color: onTap == null
                ? theme.line
                : (real ? theme.ink : theme.muted),
            fontSize: real ? 12 : 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _TimePill extends StatelessWidget {
  static const realTextStyle = TextStyle(
    fontSize: AudioTimeSeekRow.realPillFontSize,
    fontWeight: FontWeight.w500,
    height: 1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  final String text;
  final AudioPageTheme theme;
  final bool real;

  const _TimePill({required this.text, required this.theme, this.real = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('audio-time-pill'),
      height: real ? AudioTimeSeekRow.realPillHeight : null,
      alignment: real ? Alignment.center : null,
      padding: real
          ? const EdgeInsets.symmetric(
              horizontal: AudioTimeSeekRow.realPillPadding,
            )
          : const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: real ? theme.accent : theme.ink,
        borderRadius: BorderRadius.circular(
          real ? AudioTimeSeekRow.realPillRadius : 7,
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: real
            ? realTextStyle.copyWith(color: theme.canvas)
            : TextStyle(
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
  /// 真人模式（样稿 `.trans`）：两侧槽位 48dp、换章图标 26dp、
  /// 播放键图标 34dp（外圈仍是 60dp 点击区）、播放键与换章间距 40dp。
  static const realSideWidth = 48.0;
  static const realChapterIconSize = 26.0;
  static const realPlayIconSize = 34.0;
  static const realMidGap = 40.0;

  /// 真人模式的固定宽度：两侧 48 + 换章 26×2 + 播放 60 = 208dp。
  static const realFixedWidth = 208.0;

  final VoidCallback? onCatalog;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onPlayPause;
  final VoidCallback? onSleepTimer;
  final bool playing;
  final bool loading;
  final bool ready;
  final String? sleepLabel;

  /// 真人讲书模式使用样稿的 48/26/34/40dp 版式；智能朗读保持原布局。
  final bool real;

  /// 展开态只留图标，隐藏「目录」「定时」文字（样稿 `.trans.bare`）。
  final bool bare;

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
    this.real = false,
    this.bare = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = AudioPageThemeScope.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = _middleGap(constraints.maxWidth);
        final sideWidth = real ? realSideWidth : 56.0;
        final labelGap = real ? 4.0 : 2.0;
        final labelColor = real ? theme.ink : theme.muted;
        return Row(
          children: [
            _LabeledIcon(
              icon: LucideIcons.list,
              label: '目录',
              onTap: onCatalog,
              theme: theme,
              width: sideWidth,
              gap: labelGap,
              labelColor: labelColor,
              showLabel: !bare,
            ),
            const Spacer(),
            _BareIcon(
              icon: LucideIcons.skip_back,
              tooltip: '上一章',
              onTap: onPrevious,
              theme: theme,
              iconSize: real ? realChapterIconSize : 24,
              tight: real,
            ),
            SizedBox(width: gap),
            _playButton(theme),
            SizedBox(width: gap),
            _BareIcon(
              icon: LucideIcons.skip_forward,
              tooltip: '下一章',
              onTap: onNext,
              theme: theme,
              iconSize: real ? realChapterIconSize : 24,
              tight: real,
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
              width: sideWidth,
              gap: labelGap,
              labelColor: labelColor,
              showLabel: !bare,
            ),
          ],
        );
      },
    );
  }

  /// 播放键两侧的间距。真人模式固定 40dp；320dp 窄屏放不下时按剩余宽度
  /// 均分，避免 Row 溢出。
  double _middleGap(double width) {
    if (real) {
      return math.min(realMidGap, math.max(0.0, (width - realFixedWidth) / 2));
    }
    return ((width - 252) / 3).clamp(8.0, 40.0);
  }

  Widget _playButton(AudioPageTheme theme) => Semantics(
    button: true,
    child: SizedBox(
      key: const Key('audio_play'),
      width: 60,
      height: 60,
      child: IconButton(
        tooltip: playing ? '暂停' : '播放',
        onPressed: ready ? onPlayPause : null,
        padding: EdgeInsets.zero,
        iconSize: real ? realPlayIconSize : 40,
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
  );
}

class _BareIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final AudioPageTheme theme;
  final double iconSize;

  /// 真人模式使用 26dp 的紧凑点击盒；智能朗读保持原来的 IconButton 尺寸。
  final bool tight;

  const _BareIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.theme,
    this.iconSize = 24,
    this.tight = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!tight) {
      return IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        iconSize: iconSize,
        style: IconButton.styleFrom(
          foregroundColor: theme.ink,
          disabledForegroundColor: theme.line,
        ),
        icon: Icon(icon),
      );
    }
    return Tooltip(
      message: tooltip,
      child: HomePressable(
        semanticLabel: tooltip,
        onTap: onTap ?? () {},
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: iconSize,
          height: iconSize,
          child: Icon(
            icon,
            size: iconSize,
            color: onTap == null ? theme.line : theme.ink,
          ),
        ),
      ),
    );
  }
}

class _LabeledIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final AudioPageTheme theme;

  /// 激活态（例如定时已开启）用强调色。
  final bool active;

  /// 槽位宽度。智能朗读 56dp；真人模式按官方 `bin.xml` 的 minWidth 取 48dp。
  final double width;

  /// 图标与文字的间距。智能朗读 2dp；真人模式 4dp。
  final double gap;

  /// 文字颜色。为空时用主题次级色（智能朗读的原行为）。
  final Color? labelColor;

  /// 展开态的裸模式隐藏文字，只留图标。
  final bool showLabel;

  const _LabeledIcon({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.theme,
    this.active = false,
    this.width = 56,
    this.gap = 2,
    this.labelColor,
    this.showLabel = true,
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
          // 官方 minWidth 48dp。智能朗读保持 56：`AudioTransportRow` 的 gap
          // 公式把 252(=56+40+60+40+56) 当固定宽度算，改成 64 会在 320dp
          // 窄屏溢出 6.7px。「剩余本章」四个汉字 12sp 约 48dp，装得下。
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: active ? theme.accent : theme.ink),
              if (showLabel) ...[
                SizedBox(height: gap),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: active ? theme.accent : (labelColor ?? theme.muted),
                    fontSize: 12,
                    height: 1.2,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 官方封面卡的整体：12dp 圆角、正方形封面、底部渐变 + 两行页脚，
