import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';

/// 官方「更多」面板的三行快捷入口。
///
/// 反编译 `bik.xml`/`bil.xml` 里这个面板只有三行：`dh` 语速、`di` 定时、
/// `aag` 音色——都是页面上已有入口的快捷方式，而不是一个独立的设置页。
class AudioQuickRows extends StatelessWidget {
  /// 当前倍速，例如 `1.25x`。
  final String rateLabel;

  /// 定时状态文案，例如 `未开启` / `剩余本章` / `剩余播放 14:59`。
  final String timerLabel;

  /// 当前音色名。
  final String toneLabel;

  final VoidCallback onRate;
  final VoidCallback onTimer;
  final VoidCallback onTone;

  const AudioQuickRows({
    super.key,
    required this.rateLabel,
    required this.timerLabel,
    required this.toneLabel,
    required this.onRate,
    required this.onTimer,
    required this.onTone,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _row(
          palette: palette,
          key: const Key('audio_more_rate'),
          icon: LucideIcons.timer,
          title: '语速',
          value: rateLabel,
          onTap: onRate,
        ),
        _row(
          palette: palette,
          key: const Key('audio_more_timer'),
          icon: LucideIcons.alarm_clock,
          title: '定时',
          value: timerLabel,
          onTap: onTimer,
        ),
        _row(
          palette: palette,
          key: const Key('audio_more_tone'),
          icon: LucideIcons.audio_lines,
          title: '音色',
          value: toneLabel,
          onTap: onTone,
        ),
      ],
    );
  }

  Widget _row({
    required HomePalette palette,
    required Key key,
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return ListTile(
      key: key,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Icon(icon, size: 20, color: palette.ink),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: palette.ink,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
          ),
          const SizedBox(width: 2),
          Icon(LucideIcons.chevron_right, size: 14, color: palette.muted),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// 把睡眠定时状态翻成官方口径的文案。
///
/// 官方 `doc` = 「剩余本章」、`dod` = 「剩余播放」：前者是不计时长的「听完本章」，
/// 后者是分钟档的剩余时间。
String sleepTimerLabel({
  required bool atChapterEnd,
  required Duration? remaining,
}) {
  if (atChapterEnd) return '剩余本章';
  if (remaining == null) return '未开启';
  final total = remaining.inSeconds;
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '剩余播放 ${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
