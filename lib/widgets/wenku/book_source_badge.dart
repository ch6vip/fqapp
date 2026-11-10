// Ported from Wenku8_Flutter lib/book_source_badge.dart (revision ebcd7f1).
//
// Mechanical substitution: upstream `app_language.dart` `AppText` is fqapp's
// `src/app_text.dart` `AppText` (Chinese input returned unchanged).
//
// The widget itself now lives in `widgets/cover_tag_chip.dart` as
// `ShelfCoverBadge`: the archive bookshelf ported the same upstream badge into
// a second file, and the two copies had drifted apart while keeping identical
// styling. This keeps the upstream provenance note and the call site, but
// shares one implementation.

import 'package:flutter/material.dart';

import '../cover_tag_chip.dart';

class BookSourceBadge extends StatelessWidget {
  const BookSourceBadge(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => ShelfCoverBadge(text: label);
}
