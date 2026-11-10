import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../models/shuqi_book.dart';
import '../home/home_design.dart';
import 'search_media_tile.dart';

/// 经典搜索的列表行：无封面，书名 + 一行次级信息。
///
/// 长度信息放在种类旁边：500 章的长篇和 100 章的短篇差别很大，扫结果时就
/// 应该看得出来。文字格式与档案主题的 [SearchNovelRow] 共用
/// [searchMediaMeta]，两种版式不会对同一本书给出不同的信息。
class ClassicSearchResultRow extends StatelessWidget {
  final MediaItem item;
  final VoidCallback onTap;

  const ClassicSearchResultRow({
    super.key,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 13),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: palette.line, width: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                [
                  if (isShuqiItem(item)) '书旗',
                  searchMediaMeta(item),
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.muted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
