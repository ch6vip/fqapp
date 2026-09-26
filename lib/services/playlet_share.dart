/// 短剧分享：面板骨架、分享数据模型与复制链接。
///
/// 官方链路（`m0.java`）：
/// - 面板项由**服务端 token 配置**下发后再由客户端插入/删除：复制链接插到
///   列表**头部**（`:898-903`）、海报分享插在 `SYSTEM` **之前**
///   （`:1409-1483`）、抖音项被**删除**（`:878-896`）
/// - 分享数据 `GET /reading/user/share/info/v`，短剧 `share_type=Video(7)`
///   （`:930-971`）
/// - 复制链接：优先短链 `GET /reading/user/share/short_url/`，
///   失败回落到 `share_url`；写入剪贴板的是 **title + 链接**，
///   Toast 是硬编码「链接已复制，快去分享吧」（`LinkShareItem.java:117-122,174-189`）
/// - 没有可得数据时 Toast「网络错误，请重试」（`m0.java:2118`）
///
/// **项的绝对顺序依赖服务端 token，未取证**（见 F04 取证报告未取证第 1 条）。
/// 因此本面板只提供官方**可确证**的三项：复制链接（最前）、系统分享
/// （本机可用，对应 `SYSTEM`）、海报分享（在系统分享之前）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


/// 官方 `ShareType` 里短剧取 `Video`。
const shareTypeVideo = 7;

/// 官方右栏分享项的计数为 0 时的文案（0x7f061a02 = `e3t`「分享」）。
const shareEntryLabel = '分享';

/// 官方 `SeriesPostShareItem.getTextStr()`（0x7f061a21「海报分享」）。
const sharePosterLabel = '海报分享';

/// 官方「系统分享」项。
const shareSystemLabel = '系统分享';

/// 分享数据：服务端的字段一个都不改名，缺字段就是空串。
///
/// 字段名取自 `ShareInfo.java:11-94`。
@immutable
class PlayletShareInfo {
  const PlayletShareInfo({
    this.shareUrl = '',
    this.shortUrl = '',
    this.schema = '',
    this.text = '',
    this.clipboardText = '',
    this.coverUrl = '',
    this.posterCoverUrl = '',
    this.videoUrl = '',
    this.weiboShareText = '',
    this.uniqueShareId = '',
  });

  final String shareUrl;
  final String shortUrl;
  final String schema;
  final String text;
  final String clipboardText;
  final String coverUrl;
  final String posterCoverUrl;
  final String videoUrl;
  final String weiboShareText;
  final String uniqueShareId;

  /// 复制链接用的地址：官方优先短链，没有就用 `share_url`
  /// （`LinkShareItem.java:117-147`）。
  String get copyTarget => shortUrl.isNotEmpty ? shortUrl : shareUrl;

  bool get isEmpty => copyTarget.isEmpty && schema.isEmpty;

  static PlayletShareInfo fromPayload(dynamic payload) {
    final data = payload is Map && payload['data'] is Map
        ? payload['data'] as Map
        : payload;
    if (data is! Map) return const PlayletShareInfo();
    String str(String key) => data[key] == null ? '' : '${data[key]}'.trim();
    return PlayletShareInfo(
      shareUrl: str('share_url'),
      shortUrl: str('short_url'),
      schema: str('schema'),
      text: str('text'),
      clipboardText: str('clipboard_text'),
      coverUrl: str('cover_url'),
      posterCoverUrl: str('poster_cover_url'),
      videoUrl: str('video_url'),
      weiboShareText: str('weibo_share_text'),
      uniqueShareId: str('unique_share_id'),
    );
  }
}

/// 分享标题：官方兜底是「跟我一起免费看《剧名》」
/// （`m0.java:1751-1753`，右书名号 U+300B）。
String shareTitle(String seriesName) {
  final name = seriesName.trim();
  if (name.isEmpty) return '跟我一起免费看';
  return '跟我一起免费看《$name》';
}

/// 写入剪贴板的内容：官方是 **title + 链接** 直接拼接
/// （`LinkShareItem.java:176` 的 `str + str2`），没有分隔符。
String shareClipboardPayload(String title, String url) => '$title$url';

/// 一次复制的结果，供调用方决定提示哪句。
enum ShareCopyOutcome { copied, unavailable }

/// 复制链接：优先短链，失败回落长链；都没有就走「网络错误，请重试」。
///
/// [resolveShortUrl] 由调用方接后端短链接口（官方 `short_url` 路由）。
class PlayletShare {
  const PlayletShare._();

  static Future<ShareCopyOutcome> copyLink({
    required String title,
    required PlayletShareInfo info,
    Future<String> Function(String target)? resolveShortUrl,
  }) async {
    var url = info.shortUrl;
    if (url.isEmpty && info.shareUrl.isNotEmpty && resolveShortUrl != null) {
      try {
        url = await resolveShortUrl(info.shareUrl);
      } catch (_) {
        // 官方短链失败时回落长链（LinkShareItem.java:182-189）。
        url = info.shareUrl;
      }
    }
    if (url.isEmpty) url = info.shareUrl;
    if (url.isEmpty) return ShareCopyOutcome.unavailable;
    await Clipboard.setData(
      ClipboardData(text: shareClipboardPayload(title, url)),
    );
    return ShareCopyOutcome.copied;
  }

  /// 官方系统分享：`Intent.ACTION_SEND` + `text/plain`，标题用
  /// [shareTitle]，正文优先 `text`，没有就用分享链接。
  ///
  /// **返回是否真的调起了系统选择器**：Android 侧 `startActivity` 抛异常
  /// 时插件回 false（见 `SharePlugin.kt`），这里必须把它传出来——
  /// 否则「没有可分享的应用」会被显示成「已调起系统分享」。
  static Future<ShareLaunchOutcome> systemShare({
    required String title,
    required PlayletShareInfo info,
    String seriesName = '',
  }) async {
    final body = info.text.isNotEmpty
        ? info.text
        : shareClipboardPayload(shareTitle(seriesName), info.shareUrl);
    return SharePlusLite.share(title: title, text: body);
  }
}

/// 系统分享的落地结果。
enum ShareLaunchOutcome {
  /// 选择器已弹出。
  launched,

  /// 设备上没有能接住的分享目标（或宿主没注入桥）。
  unavailable,
}

/// 极简的系统分享桥。避免为一个面板引入第三方插件：官方本来就是
/// `Intent.ACTION_SEND`，这里交给宿主注入的实现（Android 侧用
/// `Intent.createChooser`）。
class SharePlusLite {
  const SharePlusLite._();

  /// 宿主注入：返回 **false 表示没能调起**（不是「已分享」）。
  static Future<bool> Function({required String title, required String text})?
  handler;

  static Future<ShareLaunchOutcome> share({
    required String title,
    required String text,
  }) async {
    final h = handler;
    if (h == null) return ShareLaunchOutcome.unavailable;
    try {
      final launched = await h(title: title, text: text);
      return launched
          ? ShareLaunchOutcome.launched
          : ShareLaunchOutcome.unavailable;
    } catch (_) {
      return ShareLaunchOutcome.unavailable;
    }
  }
}
