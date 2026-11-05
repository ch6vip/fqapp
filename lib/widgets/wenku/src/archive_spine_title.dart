// Ported from Wenku8_Flutter lib/archive_spine_title.dart (revision ebcd7f1).
//
// Mechanical substitution: upstream `app_ui.dart` `AppText` is fqapp's
// `src/app_text.dart` `AppText` (Chinese input returned unchanged).

import 'package:flutter/material.dart';

import 'app_text.dart';

/// Keep Latin words together instead of printing one letter on each line.
List<String> archiveSpineRuns(String title) {
  final runs = <String>[];
  var latin = '';
  void flush() {
    if (latin.trim().isNotEmpty) runs.add(latin.trim());
    latin = '';
  }

  for (final glyph in title.characters) {
    if (RegExp(r'^[\x20-\x7e]+$').hasMatch(glyph)) {
      latin += glyph;
    } else {
      flush();
      runs.add(glyph);
    }
  }
  flush();
  return runs;
}

class ArchiveSpineTitle extends StatelessWidget {
  const ArchiveSpineTitle(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) {
    final runs = archiveSpineRuns(title);
    const style = TextStyle(
      fontSize: 9,
      height: 1.08,
      fontWeight: FontWeight.w600,
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final run in runs.take(7))
            RegExp(r'^[\x20-\x7e]+$').hasMatch(run)
                ? RotatedBox(
                    quarterTurns: 1,
                    child: AppText(
                      run.characters.length > 24
                          ? '${run.characters.take(23)}…'
                          : run,
                      maxLines: 1,
                      style: style,
                    ),
                  )
                : AppText(run, style: style, textAlign: TextAlign.center),
          if (runs.length > 7) const AppText('…', style: style),
        ],
      ),
    );
  }
}
