import 'package:flutter/material.dart';

import '../../services/app_log.dart';
import '../home/home_chip.dart';
import '../home/home_design.dart';

class LogFilterSelection {
  const LogFilterSelection({this.level, this.timeWindow});

  final LogLevel? level;
  final Duration? timeWindow;
}

String logTimeWindowLabel(Duration? window) {
  if (window == null) return '不限时间';
  if (window.inMinutes < 60) return '最近 ${window.inMinutes} 分钟';
  return '最近 ${window.inHours} 小时';
}

/// 日志筛选面板内容：由 `showHomeSheet` 提供标题、拖拽柄与滚动。
class LogFilterSheet extends StatefulWidget {
  const LogFilterSheet({super.key, required this.initial});

  final LogFilterSelection initial;

  @override
  State<LogFilterSheet> createState() => _LogFilterSheetState();
}

class _LogFilterSheetState extends State<LogFilterSheet> {
  late LogLevel? _level = widget.initial.level;
  late Duration? _timeWindow = widget.initial.timeWindow;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _section(palette, '日志级别'),
        const SizedBox(height: 8),
        _levelChips(),
        const SizedBox(height: 20),
        _section(palette, '时间范围'),
        const SizedBox(height: 8),
        _windowChips(),
        const SizedBox(height: 24),
        _buttons(palette),
      ],
    );
  }

  Widget _levelChips() => Wrap(
    spacing: 8,
    runSpacing: 0,
    children: [
      _chip('全部级别', _level == null, () => setState(() => _level = null)),
      for (final level in LogLevel.values)
        _chip(
          level.label,
          _level == level,
          () => setState(() => _level = level),
        ),
    ],
  );

  Widget _windowChips() => Wrap(
    spacing: 8,
    runSpacing: 0,
    children: [
      for (final window in <Duration?>[
        null,
        const Duration(minutes: 5),
        const Duration(minutes: 30),
        const Duration(hours: 2),
      ])
        _chip(
          logTimeWindowLabel(window),
          _timeWindow == window,
          () => setState(() => _timeWindow = window),
        ),
    ],
  );

  /// Wrap 给的是有限最大宽，HomeChip 内部带 alignment 的容器会撑满整行；
  /// 包一层 IntrinsicWidth 让它回到胶囊的自然宽度。
  Widget _chip(String label, bool selected, VoidCallback onTap) =>
      IntrinsicWidth(
        child: HomeChip(label: label, selected: selected, onTap: onTap),
      );

  Widget _buttons(HomePalette palette) => Row(
    children: [
      OutlinedButton(
        onPressed: () => setState(() {
          _level = null;
          _timeWindow = null;
        }),
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.ink,
          side: BorderSide(color: palette.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: const Text('重置'),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: FilledButton(
          onPressed: () => Navigator.pop(
            context,
            LogFilterSelection(level: _level, timeWindow: _timeWindow),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: palette.ink,
            foregroundColor: palette.canvas,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('应用筛选'),
        ),
      ),
    ],
  );

  Widget _section(HomePalette palette, String title) => Text(
    title,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: palette.ink,
    ),
  );
}
