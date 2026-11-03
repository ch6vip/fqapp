import 'package:flutter/material.dart';

import '../../pages/audio_page.dart' show ReaderAudioBridge;

/// Borrows the global player without binding it to the book being read.
class ReaderListenCapsuleHost extends StatelessWidget {
  const ReaderListenCapsuleHost({
    super.key,
    required this.monochrome,
    this.onOpenBook,
  });

  final bool monochrome;

  /// 点封面「回到书页」：菜单本身就长在书页上，收起菜单即可，不再叠层。
  final VoidCallback? onOpenBook;

  @override
  Widget build(BuildContext context) => ReaderAudioBridge.buildMenuPlayer(
    context,
    monochrome: monochrome,
    onOpenBook: onOpenBook,
  );
}
