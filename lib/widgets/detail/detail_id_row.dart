import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_design.dart';

/// The work's id, selectable and copyable.
///
/// The value is the same id the page loads the work with, so it can be pasted
/// straight into the app's `id:` search to reopen the work.
class DetailIdRow extends StatelessWidget {
  final String id;

  /// Optional caption after the id, e.g. a sequence label.
  final String? note;

  const DetailIdRow({super.key, required this.id, this.note});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (id.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const Key('detail_id_row'),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.hash, size: 14, color: palette.muted),
          const SizedBox(width: 7),
          Expanded(
            child: SelectableText(
              id,
              key: const Key('detail_id_text'),
              maxLines: 1,
              style: TextStyle(
                color: palette.muted,
                fontSize: 12,
                height: 1.4,
                // Ids are strings of digits; a monospaced face keeps them
                // readable when compared character by character.
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (note != null && note!.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(note!, style: TextStyle(color: palette.muted, fontSize: 11)),
          ],
          _CopyIdButton(id: id),
        ],
      ),
    );
  }
}

class _CopyIdButton extends StatelessWidget {
  final String id;

  const _CopyIdButton({required this.id});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return IconButton(
      key: const Key('detail_id_copy'),
      tooltip: '复制 ID',
      onPressed: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        await Clipboard.setData(ClipboardData(text: id));
        messenger?.showSnackBar(
          const SnackBar(
            content: Text('已复制 ID'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      style: IconButton.styleFrom(
        foregroundColor: palette.muted,
        minimumSize: const Size(40, 40),
        padding: EdgeInsets.zero,
      ),
      icon: const Icon(LucideIcons.copy, size: 15),
    );
  }
}
