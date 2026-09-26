import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/playlet_share.dart';

/// 保留的分享服务兼容性用例；短剧分享面板已按用户要求移除。
///
/// 官方依据：复制链接插在列表头部、海报分享插在 SYSTEM 之前
/// （`m0.java:898-903,1409-1483`）；复制写剪贴板的是 title+链接、
/// Toast 是硬编码「链接已复制，快去分享吧」（`LinkShareItem.java:117-122,174-189`）；
/// 无数据时「网络错误，请重试」（`m0.java:2118`）；
/// 计数为 0 时右栏文案「分享」（`SeriesShareView.java:123-129`，0x7f061a02）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharePlusLite.handler = null;
  });

  group('模型与文案', () {
    test('the payload keeps the official field names', () {
      final info = PlayletShareInfo.fromPayload({
        'data': {
          'share_url': 'https://a.example/x',
          'short_url': 'https://s.example/y',
          'schema': 'snssdk143://x',
          'text': '正文',
        },
      });
      expect(info.shareUrl, 'https://a.example/x');
      expect(info.shortUrl, 'https://s.example/y');
      expect(info.schema, 'snssdk143://x');
      expect(info.text, '正文');
      expect(info.isEmpty, isFalse);
    });

    test('an empty payload counts as unavailable', () {
      final info = PlayletShareInfo.fromPayload(const {'data': {}});
      expect(info.isEmpty, isTrue);
    });

    test('the title uses the official fallback wording', () {
      expect(shareTitle('我的短剧'), '跟我一起免费看《我的短剧》');
      expect(shareTitle(''), '跟我一起免费看');
    });

    test('the clipboard payload is title concatenated with the link', () {
      expect(shareClipboardPayload('标题', 'https://x'), '标题https://x');
    });

    test('copy prefers the short url', () async {
      String? written;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              written = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final outcome = await PlayletShare.copyLink(
        title: '标题',
        info: const PlayletShareInfo(
          shareUrl: 'https://long',
          shortUrl: 'https://short',
        ),
      );
      expect(outcome, ShareCopyOutcome.copied);
      expect(written, '标题https://short');
    });

    test(
      'copy falls back to the long url when the short url call fails',
      () async {
        String? written;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                written = (call.arguments as Map)['text'] as String?;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );
        final outcome = await PlayletShare.copyLink(
          title: '标题',
          info: const PlayletShareInfo(shareUrl: 'https://long'),
          resolveShortUrl: (target) async => throw Exception('短链失败'),
        );
        expect(outcome, ShareCopyOutcome.copied);
        expect(written, '标题https://long');
      },
    );

    test('copy without any url reports unavailable', () async {
      final outcome = await PlayletShare.copyLink(
        title: '标题',
        info: const PlayletShareInfo(),
      );
      expect(outcome, ShareCopyOutcome.unavailable);
    });
  });

  group('系统分享的落地结果', () {
    test('没有注入桥时报告不可用（不假装已分享）', () async {
      SharePlusLite.handler = null;
      final outcome = await PlayletShare.systemShare(
        title: '标题',
        info: const PlayletShareInfo(shareUrl: 'https://a.example/x'),
        seriesName: '剧名',
      );
      expect(outcome, ShareLaunchOutcome.unavailable);
    });

    test('桥回 false 时报告不可用', () async {
      SharePlusLite.handler = ({required title, required text}) async => false;
      final outcome = await PlayletShare.systemShare(
        title: '标题',
        info: const PlayletShareInfo(shareUrl: 'https://a.example/x'),
        seriesName: '剧名',
      );
      expect(outcome, ShareLaunchOutcome.unavailable);
    });

    test('桥回 true 时才报告已调起', () async {
      SharePlusLite.handler = ({required title, required text}) async => true;
      final outcome = await PlayletShare.systemShare(
        title: '标题',
        info: const PlayletShareInfo(shareUrl: 'https://a.example/x'),
        seriesName: '剧名',
      );
      expect(outcome, ShareLaunchOutcome.launched);
    });

    test('桥抛异常也报告不可用', () async {
      SharePlusLite.handler = ({required title, required text}) async =>
          throw Exception('没有可分享的应用');
      final outcome = await PlayletShare.systemShare(
        title: '标题',
        info: const PlayletShareInfo(shareUrl: 'https://a.example/x'),
        seriesName: '剧名',
      );
      expect(outcome, ShareLaunchOutcome.unavailable);
    });

    test('分享正文优先用 text，没有则用标题+链接', () async {
      String? seen;
      SharePlusLite.handler = ({required title, required text}) async {
        seen = text;
        return true;
      };
      await PlayletShare.systemShare(
        title: '标题',
        info: const PlayletShareInfo(
          text: '正文',
          shareUrl: 'https://a.example/x',
        ),
        seriesName: '剧名',
      );
      expect(seen, '正文');
      await PlayletShare.systemShare(
        title: '标题',
        info: const PlayletShareInfo(shareUrl: 'https://a.example/x'),
        seriesName: '剧名',
      );
      expect(seen, contains('https://a.example/x'));
      expect(seen, contains('跟我一起免费看'));
    });
  });
}
