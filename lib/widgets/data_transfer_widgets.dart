import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'home/home_design.dart';

/// Shared settings surfaces for local backups and upstream imports.
class DataTransferCard extends StatelessWidget {
  final List<Widget> children;
  const DataTransferCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Material(
      color: palette.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

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
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: HomePalette.accent.withValues(alpha: .1),
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

class DataTransferRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  const DataTransferRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return ListTile(
      enabled: onTap != null,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: palette.soft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: palette.accentText),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: onTap == null ? palette.muted : palette.ink,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          subtitle,
          style: TextStyle(color: palette.muted, height: 1.5, fontSize: 12.5),
        ),
      ),
      trailing: Icon(LucideIcons.chevron_right, size: 18, color: palette.muted),
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
    final color = error
        ? Theme.of(context).colorScheme.error
        : palette.accentText;
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
  Widget build(BuildContext context) => FilledButton(
    style: FilledButton.styleFrom(
      backgroundColor: HomePalette.of(context).eink
          ? Colors.black
          : HomePalette.accentStrong,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    onPressed: onPressed,
    child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
  );
}
