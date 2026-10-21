import 'package:flutter/material.dart';

import '../models/media_item.dart';
import 'shelf_store.dart';

/// 「加入书架」的共用动作（issue #103）。
///
/// 详情页有自己的实现（`detail_page.dart`）。阅读器、漫画阅读器这类没有详情页的
/// 界面也要能加书架，提示语与「书架没起来」的兜底保持一致，所以收在这里。
bool inShelf(MediaItem item) => ShelfStore.instance.containsItem(item);

/// 切换 [item] 的书架状态并提示结果。
///
/// 书架不可用（Hive 没起来）时只提示、不抛异常，也不假装成功。
Future<void> toggleShelf(BuildContext context, MediaItem item) async {
  if (!ShelfStore.instance.isReady) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地书架暂不可用，请重试')),
      );
    }
    return;
  }
  final added = await ShelfStore.instance.toggle(item);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(added ? '已加入书架' : '已移出书架'),
      duration: const Duration(seconds: 2),
    ),
  );
}
