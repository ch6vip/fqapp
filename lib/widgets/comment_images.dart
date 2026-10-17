import 'package:flutter/material.dart';

import '../services/chapter_text_formatter.dart';
import 'reader/reader_illustration.dart';

class CommentImages extends StatelessWidget {
  const CommentImages({super.key, required this.imageUrls});

  final List<String> imageUrls;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final url in imageUrls)
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: imageUrls.length == 1 ? 144 : 96,
            height: imageUrls.length == 1 ? 180 : 96,
            child: ReaderIllustration(
              image: ChapterImage(url: url, alt: '评论配图'),
            ),
          ),
        ),
    ],
  );
}
