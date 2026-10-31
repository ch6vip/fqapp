import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/chapter_ideas.dart';

/// Keep each chapter's comments with its divider, including inactive neighbours.
class ReaderJoinedChapterEnd extends StatelessWidget {
  const ReaderJoinedChapterEnd({
    super.key,
    required this.index,
    required this.ideas,
    required this.onComments,
  });

  final int index;
  final ChapterIdeas ideas;
  final VoidCallback onComments;

  // Match the measured sliver extent even with accessibility text scaling.
  static double height(TextScaler scaler, bool hasComments) => hasComments
      ? math.max(20, scaler.scale(12) * 1.4) +
            math.max(48, scaler.scale(14) * 1.4 + 16) +
            12
      : 56;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      if (ideas.isNotEmpty)
        TextButton.icon(
          key: ValueKey('reader-joined-chapter-comments-$index'),
          onPressed: onComments,
          icon: const Icon(LucideIcons.message_square, size: 18),
          label: Text(
            '本章评论 ${ideas.total}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
        ),
      Row(
        children: [
          const Expanded(child: Divider()),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('本章完', style: TextStyle(fontSize: 12, height: 1.4)),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    ],
  );
}
