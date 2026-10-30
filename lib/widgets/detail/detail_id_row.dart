import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../home/home_design.dart';

/// The work's id, selectable and copyable.
///
/// The redesign drops the card: it is one small monospace line at the very
/// bottom of the page. The value is the same id the page loads the work with,
/// so it can be pasted straight into the app's `id:` search.
class DetailIdRow extends StatelessWidget {
  final String id;
  final bool compact;

  /// Optional caption after the id, e.g. a sequence label.
  final String? note;

  const DetailIdRow({
    super.key,
    required this.id,
    this.note,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    if (id.isEmpty) return const SizedBox.shrink();
    final mono = TextStyle(
      color: palette.muted,
      fontSize: compact ? 12 : 11,
      height: 1.4,
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      key: const Key('detail_id_row'),
      padding: EdgeInsets.symmetric(vertical: compact ? 4 : 18),
      child: Row(
        children: [
          Text('ID', style: mono),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              id,
              key: const Key('detail_id_text'),
              maxLines: 1,
              style: mono,
            ),
          ),
          if (note != null && note!.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(note!, style: mono),
          ],
          TextButton(
            key: const Key('detail_id_copy'),
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
            style: TextButton.styleFrom(
              foregroundColor: palette.muted,
              minimumSize: const Size(48, 40),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('复制', style: mono),
          ),
        ],
      ),
    );
  }
}
