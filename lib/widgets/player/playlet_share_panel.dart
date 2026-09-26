/// 短剧分享面板。
///
/// 官方面板项由服务端 token（`1967_shortvideo_2`）下发后客户端再插入/删除，
/// 客户端**可确证**的只有三条（`m0.java:878-903,1409-1483`）：
/// 复制链接在最前、海报分享在系统分享之前、抖音项被删除。
/// 绝对顺序依赖服务端配置，**未取证**，所以这里只提供这三项可确证的：
/// 复制链接 / 系统分享 / 海报分享，并保留同样的先后关系。
///
/// 复制反馈用官方硬编码串「链接已复制，快去分享吧」；没有可得数据时用
/// 「网络错误，请重试」（`m0.java:2118`）。
library;

import 'package:flutter/material.dart';

import '../../models/playlet_comment.dart';
import '../../services/playlet_share.dart';

class PlayletSharePanel extends StatelessWidget {
  const PlayletSharePanel({
    super.key,
    required this.title,
    required this.info,
    required this.seriesName,
    this.resolveShortUrl,
    this.onPoster,
  });

  /// 官方标题：`《剧名》免费看全集`（`m0.java:1913-1919`）。
  final String title;
  final PlayletShareInfo info;
  final String seriesName;

  /// 短链兜底（官方 `share/short_url`）。
  final Future<String> Function(String target)? resolveShortUrl;

  /// 海报分享；为 null 时该项不出现（官方该项由
  /// `ShortSeriesSharePanelExp.isSupportImageShare` 控制）。
  final VoidCallback? onPoster;

  /// 面板入口：先取分享数据再弹面板；取不到数据时按官方给
  /// 「网络错误，请重试」。
  static Future<void> show(
    BuildContext context, {
    required String title,
    required PlayletShareInfo info,
    required String seriesName,
    Future<String> Function(String target)? resolveShortUrl,
    VoidCallback? onPoster,
  }) async {
    if (info.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(shareUnavailableToast)));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => PlayletSharePanel(
        title: title,
        info: info,
        seriesName: seriesName,
        resolveShortUrl: resolveShortUrl,
        onPoster: onPoster,
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final outcome = await PlayletShare.copyLink(
      title: title,
      info: info,
      resolveShortUrl: resolveShortUrl,
    );
    navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome == ShareCopyOutcome.copied
              ? shareCopiedToast
              : shareUnavailableToast,
        ),
      ),
    );
  }

  Future<void> _systemShare(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    navigator.pop();
    await PlayletShare.systemShare(
      title: title,
      info: info,
      seriesName: seriesName,
    );
    messenger.showSnackBar(const SnackBar(content: Text('已调起系统分享')));
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            key: const ValueKey('playlet-share-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, color: Color(0xFF1B1B1B)),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              // 官方把复制链接插在列表头部。
              _item(
                'playlet-share-copy-link',
                Icons.link_rounded,
                shareCopyLinkLabel,
                () => _copy(context),
              ),
              // 官方把海报分享**插在 `SYSTEM` 之前**（`m0.java:1409-1483` 的
              // `list2.add(size, item)`，size 是第一个 SYSTEM 的下标），
              // 所以顺序是 复制链接 -> 海报分享 -> 系统分享。
              if (onPoster != null)
                _item(
                  'playlet-share-poster',
                  Icons.image_rounded,
                  sharePosterLabel,
                  onPoster!,
                ),
              _item(
                'playlet-share-system',
                Icons.ios_share_rounded,
                shareSystemLabel,
                () => _systemShare(context),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _item(
    String key,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) => GestureDetector(
    key: ValueKey(key),
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: SizedBox(
      width: 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              color: Color(0xFFF2F2F4),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 24, color: const Color(0xFF1B1B1B)),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
          ),
        ],
      ),
    ),
  );
}
