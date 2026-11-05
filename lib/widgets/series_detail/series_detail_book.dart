import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_detail.dart' show formatWordCount;
import '../../models/series_detail.dart' show SeriesRelateBook;
import '../../services/api_client.dart';
import '../home/home_design.dart';
import '../home/home_archive.dart';
import '../home/home_media_card.dart';
import '../../models/media_item.dart';
import 'series_detail_common.dart';

/// Original novel entry: the entire bordered row opens its detail page.
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
          const SeriesSectionHeader(code: 'ORIGINAL', title: '原著小说'),
          HomePressable(
            semanticLabel: '查看原著 ${book.title}',
            onTap: onOpen,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(homePanelRadius),
                border: Border.all(color: palette.line),
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
                  Icon(
                    LucideIcons.chevron_right,
                    size: 20,
                    color: palette.muted,
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
    borderRadius: BorderRadius.circular(homeCoverRadius),
    child: SizedBox(
      width: 48,
      height: 66,
      child: StoryCover(
        item: MediaItem(
          id: book.id,
          title: book.title,
          cover: book.cover.isEmpty
              ? ''
              : ApiClient.instance.absoluteUrl(book.cover),
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        ),
        cacheWidth: 160,
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
