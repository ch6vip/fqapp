import 'package:flutter/material.dart';

import '../../pages/audio_page.dart' show ReaderAudioBridge;

/// Borrows the global player without binding it to the book being read.
class ReaderListenCapsuleHost extends StatelessWidget {
  const ReaderListenCapsuleHost({super.key, required this.monochrome});

  final bool monochrome;

  @override
  Widget build(BuildContext context) =>
      ReaderAudioBridge.buildMenuPlayer(context, monochrome: monochrome);
}
