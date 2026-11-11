import 'package:flutter/material.dart';

import '../services/chapter_text_formatter.dart';
import 'reader/reader_illustration.dart';

class CommentImages extends StatelessWidget {
  const CommentImages({super.key, required this.imageUrls});

  final List<String> imageUrls;

  /// 评论配图在列表里最大只有 144×180 逻辑像素；按 3× 屏算 432×540 就够。
  /// 之前和章节插图共用 2048×4096 的解码上限，单张位图最多约 33 MiB，
  /// 九宫格配图在 8 GiB 机型上会明显放大内存压力（#266）。
  static const maxDecodeWidth = 480;
  static const maxDecodeHeight = 600;

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
              maxDecodeWidth: maxDecodeWidth,
              maxDecodeHeight: maxDecodeHeight,
            ),
          ),
        ),
    ],
  );
}
