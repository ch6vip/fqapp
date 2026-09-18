import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';
import 'reader_theme.dart';

/// What the reader can do with a long-pressed paragraph.
enum ReaderParagraphAction { copy, listen, underline, removeUnderline }

/// Long-press sheet for a paragraph, mirroring the official paragraph actions.
///
/// The official client shows 划线 / 写想法 / 复制 / 从本段听. 写想法 and 摘录 need
/// account-side endpoints  does not have, so this offers 复制, 从本段听 and
/// the locally stored 划线. See
/// .agents/notes/implemented/feature/2026-09-18-reader-paragraph-actions.md
class ReaderParagraphMenu extends StatelessWidget {
  final ReaderThemePreset preset;
  final bool underlined;

  const ReaderParagraphMenu({
    super.key,
    required this.preset,
    this.underlined = false,
  });

  static Future<ReaderParagraphAction?> show(
    BuildContext context, {
    required ReaderThemePreset preset,
    required bool underlined,
  }) => showModalBottomSheet<ReaderParagraphAction>(
    context: context,
    showDragHandle: false,
    backgroundColor: preset.isDark ? preset.panelColor : Colors.white,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (context) =>
        ReaderParagraphMenu(preset: preset, underlined: underlined),
  );

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: preset.theme(Theme.of(context)),
      child: SafeArea(
        top: false,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Row(
                key: const ValueKey('reader-action-copy'),
                icon: Icons.copy_rounded,
                label: '复制',
                color: preset.textColor,
                onTap: () => Navigator.pop(context, ReaderParagraphAction.copy),
              ),
              _Row(
                key: const ValueKey('reader-action-listen'),
                icon: Icons.headphones_outlined,
                label: '从本段听',
                color: preset.textColor,
                onTap: () =>
                    Navigator.pop(context, ReaderParagraphAction.listen),
              ),
              _Row(
                key: const ValueKey('reader-action-underline'),
                icon: underlined
                    ? Icons.format_color_reset_rounded
                    : Icons.edit_rounded,
                label: underlined ? '取消划线' : '划线',
                color: underlined ? preset.accentColor : preset.textColor,
                onTap: () => Navigator.pop(
                  context,
                  underlined
                      ? ReaderParagraphAction.removeUnderline
                      : ReaderParagraphAction.underline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _Row({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, size: 20, color: color),
    title: Text(label, style: TextStyle(fontSize: 15, color: color)),
    onTap: onTap,
  );
}
