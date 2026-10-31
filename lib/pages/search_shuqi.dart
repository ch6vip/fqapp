import '../models/media_item.dart';
import '../models/shuqi_book.dart';

/// 书旗搜索的加载函数。
typedef ShuqiSearchLoader = Future<Map<String, dynamic>> Function(String key);

/// 书旗搜索：单次返回全量结果，按 `kind:id` 去重。
///
/// 后端已经把条目归一化成 `shuqiMediaItemFromSearch` 认识的形状；这里只做
/// 去重，避免同一本书在多个推荐模块里重复出现。
Future<List<MediaItem>> loadShuqiSearch(
  ShuqiSearchLoader loader,
  String query,
) async {
  final payload = await loader(query);
  final data = payload['data'];
  final items = <MediaItem>[];
  final seen = <String>{};
  if (data is List) {
    for (final entry in data) {
      if (entry is! Map) continue;
      final item = shuqiMediaItemFromSearch(Map<String, dynamic>.from(entry));
      if (item.id.isEmpty) continue;
      if (seen.add('${item.kind}:${item.id}')) items.add(item);
    }
  }
  return items;
}
