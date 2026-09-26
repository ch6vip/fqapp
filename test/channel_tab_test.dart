import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/channel_tab.dart';

/// F08：服务端频道表。
///
/// 官方**不用静态频道表**：`m0.java:3051-3089` 把 `BookstoreTabResponse`
/// 的 `data.tab_item`（`TabDataList.tabItem`）逐条转成 `BookMallTabData`，
/// 名字取 `bookstoreTabData.title`（`:3058`，为空则空串）、类型取
/// `tab_type`（`:3086`）、可见性由条目本身是否存在决定。
void main() {
  test('parses the server channel table in order', () {
    final tabs = ChannelTab.listFromPayload({
      'code': 0,
      'data': {
        'tab_item': [
          {'tab_type': 2, 'title': '推荐'},
          {'tab_type': 4, 'title': '看剧'},
          {'tab_type': 18, 'title': '最近'},
          {'tab_type': 30, 'title': '收藏'},
        ],
      },
    });
    expect(tabs.map((tab) => tab.title), ['推荐', '看剧', '最近', '收藏']);
    expect(tabs.map((tab) => tab.type), [2, 4, 18, 30]);
  });

  test('maps the seriesmall strip labels to the official tab types', () {
    // 注意区分两件事：官方枚举里的 `recommend` 是 2，但**短剧频道条上的
    // 「推荐」不是它** —— 本仓库既有实现（drama_page.dart 的注释，同样是
    // 官方取证结论）把该频道标成 `video_feed = 16`：书城页把 16 叫「视频」，
    // 而 seriesmall 页把同一条流叫「推荐」。
    expect(ChannelTab.typeOf('推荐'), kChannelVideoFeed);
    expect(ChannelTab.typeOf('看剧'), kChannelVideoEpisode);
    expect(ChannelTab.typeOf('漫剧'), kChannelDynamicComic);
    expect(ChannelTab.typeOf('最近'), kChannelRecent);
    expect(ChannelTab.typeOf('收藏'), kChannelFollow);
    // 表里没有的名字返回 null，调用方自己决定怎么处理。
    expect(ChannelTab.typeOf('不存在的频道'), isNull);
    // 官方枚举的原始值（`BookstoreTabType`）保留成常量，便于对照。
    expect(kChannelRecommend, 2);
    expect(kChannelVideo, 4);
    expect(kChannelVideoFeed, 16);
  });

  test('an empty title falls back to the empty string', () {
    // 官方 `if (str == null) str = "";`（`m0.java:3058-3061`）。
    final tabs = ChannelTab.listFromPayload({
      'data': {
        'tab_item': [
          {'tab_type': 2},
        ],
      },
    });
    expect(tabs.single.title, '');
  });

  test('entries without a usable tab_type are dropped', () {
    final tabs = ChannelTab.listFromPayload({
      'data': {
        'tab_item': [
          {'tab_type': 2, 'title': '推荐'},
          {'title': '缺类型'},
          {'tab_type': 'x', 'title': '类型非法'},
        ],
      },
    });
    expect(tabs.map((tab) => tab.title), ['推荐']);
  });

  test('a missing or malformed table yields nothing', () {
    expect(ChannelTab.listFromPayload(const {}), isEmpty);
    expect(ChannelTab.listFromPayload(const {'data': {}}), isEmpty);
    expect(
      ChannelTab.listFromPayload(const {
        'data': {'tab_item': 'nope'},
      }),
      isEmpty,
    );
    expect(ChannelTab.listFromPayload(const {'code': 1001}), isEmpty);
  });

  test('recent and follow are client-filled channels', () {
    // 官方这两个频道的数据来自设备自身（历史/书架），不是 feed。
    expect(ChannelTab(type: kChannelRecent, title: '最近').isLocal, isTrue);
    expect(ChannelTab(type: kChannelFollow, title: '收藏').isLocal, isTrue);
    expect(ChannelTab(type: kChannelRecommend, title: '推荐').isLocal, isFalse);
  });
}
