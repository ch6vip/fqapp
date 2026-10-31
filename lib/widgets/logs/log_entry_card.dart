import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/app_log.dart';
import '../home/home_design.dart';
import '../shelf/shelf_design.dart';

/// Collapsed summaries keep stack traces from taking over the log list.
class LogEntryCard extends StatefulWidget {
  const LogEntryCard({super.key, required this.entry, required this.onCopy});

  final LogEntry entry;
  final VoidCallback onCopy;

  @override
  State<LogEntryCard> createState() => _LogEntryCardState();
}

class _LogEntryCardState extends State<LogEntryCard> {
  bool _expanded = false;

  /// 级别色：墨水屏一律纯黑，保证警告 / 错误在灰度屏上可读；其余外观
  /// 沿用原来的四档语义色。
  Color _levelColor(HomePalette palette, LogLevel level) {
    if (palette.eink) return Colors.black;
    return switch (level) {
      LogLevel.debug => palette.muted,
      LogLevel.info => palette.accentText,
      LogLevel.warn =>
        palette.dark ? const Color(0xFFFFCF7C) : const Color(0xFF805300),
      LogLevel.error => ShelfTokens.deleteRed,
    };
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final palette = HomePalette.of(context);
    final color = _levelColor(palette, entry.level);
    final time = entry.time.toLocal();
    final timestamp = time.toIso8601String();
    final messageStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      height: 1.5,
      color: palette.ink,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: palette.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: palette.line, width: 0.6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              expanded: _expanded,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _levelBadge(palette, color),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              entry.tag,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: palette.ink,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            timestamp.substring(11, 19),
                            style: TextStyle(
                              fontSize: 11,
                              color: palette.muted,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            _expanded
                                ? LucideIcons.chevron_up
                                : LucideIcons.chevron_down,
                            size: 18,
                            color: palette.muted,
                          ),
                        ],
                      ),
                      if (!_expanded) ...[
                        const SizedBox(height: 8),
                        Text(
                          entry.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: messageStyle,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      '${timestamp.replaceFirst('T', ' ')} · ${entry.tag}',
                      style: TextStyle(fontSize: 11, color: palette.muted),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(entry.message, style: messageStyle),
                    const SizedBox(height: 4),
                    TextButton.icon(
                      onPressed: widget.onCopy,
                      style: TextButton.styleFrom(
                        foregroundColor: palette.accentText,
                      ),
                      icon: const Icon(LucideIcons.copy, size: 16),
                      label: const Text('复制单条'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _levelBadge(HomePalette palette, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: palette.eink ? Colors.transparent : color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: palette.eink
            ? Border.all(color: Colors.black, width: 0.6)
            : null,
      ),
      child: Text(
        widget.entry.level.label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
