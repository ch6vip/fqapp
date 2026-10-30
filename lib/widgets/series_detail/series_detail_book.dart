import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/book_detail.dart' show formatWordCount;
import '../../models/series_detail.dart' show SeriesRelateBook;
import '../../services/api_client.dart';
import '../home/home_design.dart';
import 'series_detail_common.dart';

/// 原著小说：15sp 区块头 + 一张 surface 卡（40×54 封面、书名、
/// `完结 · 186万字` 灰字、右侧小号「立即阅读」胶囊）。
class SeriesDetailBookSection extends StatelessWidget {
  const SeriesDetailBookSection({
    super.key,
    required this.book,
    required this.onOpen,
  });

  final SeriesRelateBook book;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final meta = _meta();
    return SeriesSection(
      key: const ValueKey('series-detail-original-book'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SeriesSectionHeader(title: '原著小说'),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(10),
                border: palette.eink ? Border.all(color: palette.line) : null,
              ),
              child: Row(
                children: [
                  _cover(palette),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: palette.ink),
                        ),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: palette.muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: palette.line),
                    ),
                    child: Text(
                      '立即阅读',
                      style: TextStyle(fontSize: 12, color: palette.ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cover(HomePalette palette) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: book.cover.isEmpty
        ? SizedBox(
            width: 40,
            height: 54,
            child: ColoredBox(color: palette.soft),
          )
        : CachedNetworkImage(
            imageUrl: ApiClient.instance.absoluteUrl(book.cover),
            width: 40,
            height: 54,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => SizedBox(
              width: 40,
              height: 54,
              child: ColoredBox(color: palette.soft),
            ),
          ),
  );

  /// `creation_status`：书籍语义 0=完结、1=连载；外加字数。
  String _meta() {
    final status = switch (book.status.trim()) {
      '0' => '完结',
      '1' => '连载',
      final other => other,
    };
    final words = formatWordCount(book.wordCount);
    return [
      if (status.isNotEmpty) status,
      if (words.isNotEmpty) words,
    ].join(' · ');
  }
}
