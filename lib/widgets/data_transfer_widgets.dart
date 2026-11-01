import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home/home_design.dart';

/// Shared surfaces for local backups and upstream imports.
///
/// 卡片与行已统一到设置组件 SettingsGroupCard / SettingsRow，这里只保留
/// 备份 / 导入这类数据页专属的头部、统计块、结果提示与主按钮。
class DataTransferHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const DataTransferHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: palette.accentText, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DataTransferStats extends StatelessWidget {
  final Map<String, int> values;
  const DataTransferStats({super.key, required this.values});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    // Wrap keeps enlarged system text and narrow windows readable.
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final entry in values.entries)
          Container(
            constraints: const BoxConstraints(minWidth: 80),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.value}',
                  style: TextStyle(
                    color: palette.ink,
                    fontSize: 23,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  entry.key,
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class DataTransferNotice extends StatelessWidget {
  final String message;
  final bool error;
  const DataTransferNotice({
    super.key,
    required this.message,
    this.error = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final color = error ? palette.ink : palette.accentText;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: error ? color.withValues(alpha: .4) : palette.line,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error ? LucideIcons.circle_alert : LucideIcons.circle_check,
              color: color,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: palette.ink, height: 1.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DataTransferAction extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const DataTransferAction({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accentText,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}
