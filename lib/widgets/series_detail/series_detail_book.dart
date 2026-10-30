import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/series_detail.dart' show SeriesRelateBook;
import '../../services/api_client.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart' show HomeSectionHeader, homeGutter;

/// 原著小说：标题 + 书卡（封面 / 书名 / 「立即阅读」胶囊钮）。
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
    return Column(
      key: const ValueKey('series-detail-original-book'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HomeSectionHeader(title: '原著小说'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(10),
                border: palette.eink ? Border.all(color: palette.line) : null,
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: book.cover.isEmpty
                        ? SizedBox(
                            width: 40,
                            height: 54,
                            child: ColoredBox(color: palette.soft),
                          )
                        : CachedNetworkImage(
                            imageUrl: ApiClient.instance.absoluteUrl(
                              book.cover,
                            ),
                            width: 40,
                            height: 54,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => SizedBox(
                              width: 40,
                              height: 54,
                              child: ColoredBox(color: palette.soft),
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: palette.ink,
                      ),
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
        ),
      ],
    );
  }
}
