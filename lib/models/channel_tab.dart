/// 服务端频道表（F08）。
///
/// 官方**不用静态频道表**：`GET /reading/bookapi/bookmall/tab/v`（`ro4/b.java:224-227`）
/// 返回 `BookstoreTabResponse`，其 `data: TabDataList` 的 `tab_item` 是
/// `List<BookstoreTabData>`；客户端在 `m0.java:3051-3089` 逐条转成 `BookMallTabData`，
/// **名字取 `bookstoreTabData.title`**（`:3058`，null 当空串）、
/// **类型取 `tab_type`**（`:3086`）。所以频道条的名字、顺序、可见性都由服务端决定。
library;

import 'package:flutter/foundation.dart';

/// 官方 `BookstoreTabType`（`com/bytedance/kmp/reading/model/BookstoreTabType.java`）
/// 里与本页相关的取值。
const int kChannelRecommend = 2;
const int kChannelVideo = 4;
const int kChannelVideoEpisode = 8;
const int kChannelVideoFeed = 16;
const int kChannelRecent = 18;
const int kChannelDynamicComic = 24;
const int kChannelFollow = 30;

/// 一个服务端下发的频道。
@immutable
class ChannelTab {
  const ChannelTab({required this.type, required this.title});

  /// 服务端 `tab_type`。
  final int type;

  /// 服务端 `title`（官方为 null 时落成空串）。
  final String title;

  /// 「最近」与「收藏」的数据来自设备自身（历史 / 书架），不是 feed。
  bool get isLocal => type == kChannelRecent || type == kChannelFollow;

  @override
  String toString() => 'ChannelTab($type, "$title")';

  /// 官方中文名 -> `tab_type`。表里没有的名字返回 null（调用方决定怎么处理）。
  static int? typeOf(String name) => switch (name.trim()) {
    '推荐' => kChannelVideoFeed,
    '看剧' => kChannelVideoEpisode,
    '漫剧' => kChannelDynamicComic,
    '最近' => kChannelRecent,
    '收藏' => kChannelFollow,
    _ => null,
  };

  /// 解析 `BookstoreTabResponse`。
  ///
  /// 与官方一致的三点：按 `tab_item` 原序、`title` 缺失落空串、
  /// 没有可用 `tab_type` 的条目直接丢弃（官方只按存在与否处理，
  /// 本地多做一步类型校验，避免把脏数据变成乱码频道）。
  static List<ChannelTab> listFromPayload(dynamic payload) {
    if (payload is! Map) return const [];
    final code = payload['code'];
    if (code is num && code != 0 && code != 200) return const [];
    final data = payload['data'];
    if (data is! Map) return const [];
    final items = data['tab_item'];
    if (items is! List) return const [];
    final out = <ChannelTab>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final type = _intOf(raw['tab_type']);
      if (type == null) continue;
      out.add(ChannelTab(type: type, title: raw['title']?.toString() ?? ''));
    }
    return List.unmodifiable(out);
  }

  static int? _intOf(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}
