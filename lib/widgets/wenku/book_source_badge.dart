// Ported from Wenku8_Flutter lib/book_source_badge.dart (revision ebcd7f1).
//
// Mechanical substitution: upstream `app_language.dart` `AppText` is fqapp's
// `src/app_text.dart` `AppText` (Chinese input returned unchanged).

import 'package:flutter/material.dart';

import 'src/app_text.dart';

class BookSourceBadge extends StatelessWidget {
  const BookSourceBadge(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: AppText(
          label,
          maxLines: 1,
          style: TextStyle(
            color: colors.onSurface,
            fontSize: 9,
            height: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
