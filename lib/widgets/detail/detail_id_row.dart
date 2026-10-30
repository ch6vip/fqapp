import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../home/home_design.dart';
import 'detail_style.dart';

/// The work's id, selectable and copyable.
///
/// Mockup: one 11dp muted line at the very bottom, padding 22/18, `ID xxx`
/// then `复制`. Digits use the inherited font with tabular figures — never
/// `monospace`, which resolves to a typewriter face on some phones. The old
/// card is gone; the value is the same id the page loads the work with, so it
/// can be pasted into the app's `id:` search.
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
      height: 1.5,
      fontFeatures: detailNumericFeatures,
    );
    return Padding(
      key: const Key('detail_id_row'),
      padding: EdgeInsets.only(top: compact ? 4 : 22, bottom: compact ? 4 : 18),
      child: Row(
        children: [
          Text('ID', style: mono),
          const SizedBox(width: 8),
          Flexible(
            fit: FlexFit.loose,
            child: SelectableText(
              id,
              key: const Key('detail_id_text'),
              maxLines: 1,
              style: mono,
            ),
          ),
          if (note != null && note!.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(note!, style: mono),
          ],
          const SizedBox(width: 8),
          HomePressable(
            key: const Key('detail_id_copy'),
            semanticLabel: '复制 ID',
            borderRadius: BorderRadius.circular(4),
            onTap: () async {
              final messenger = ScaffoldMessenger.maybeOf(context);
              await Clipboard.setData(ClipboardData(text: id));
              messenger?.showSnackBar(
                const SnackBar(
                  content: Text('已复制 ID'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: Text('复制', style: mono),
          ),
        ],
      ),
    );
  }
}
