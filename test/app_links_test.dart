import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/app_links.dart';

/// Upstream ships every jump target as a `dragon1967://` intent, and the real
/// targets are buried one or two `?url=` hops down. `url_launcher` cannot open
/// the outer link at all, so the resolver has to dig the https page out — this
/// pins the two shapes the bookstore feed actually sends.
void main() {
  group('resolveAppLink', () {
    test('passes a plain https link through', () {
      expect(
        resolveAppLink('https://example.com/page?a=1')?.toString(),
        'https://example.com/page?a=1',
      );
    });

    test('unwraps dragon1967://webview one hop', () {
      // 话题行的真实形态（`topic_data[i].url`）。
      const raw =
          'dragon1967://webview?loadingButHideByFront=1&hideNavigationBar=1'
          '&url=https%3A%2F%2Freading.snssdk.com%2Freading_offline%2Fdrweb'
          '%2Fpage%2Ftopic-book-list.html%3Ftopic_id%3D7381334221975339547'
          '&bookId=11111&topicId=7381334221975339547';

      expect(
        resolveAppLink(raw)?.toString(),
        'https://reading.snssdk.com/reading_offline/drweb/page/'
        'topic-book-list.html?topic_id=7381334221975339547',
      );
    });

    test('unwraps lynxview → fallbackUrl → webview', () {
      // 卡片的真实形态（`cell_url`）：两层嵌套。
      const raw =
          'dragon1967://lynxview?hideStatusBar=1'
          '&fallbackUrl=dragon1967%3A%2F%2Fwebview%3Furl%3D'
          'https%253A%252F%252Freading.snssdk.com%252Fhot-topic.html'
          '&url=sslocal%3A%2F%2Flynxview%3Ftemplate.js';

      expect(
        resolveAppLink(raw)?.toString(),
        'https://reading.snssdk.com/hot-topic.html',
      );
    });

    test('prefers url over fallbackUrl', () {
      const raw =
          'dragon1967://webview?url=https%3A%2F%2Fexample.com%2Fprimary'
          '&fallbackUrl=https%3A%2F%2Fexample.com%2Ffallback';

      expect(resolveAppLink(raw)?.toString(), 'https://example.com/primary');
    });

    test('returns null when nothing openable is in there', () {
      expect(resolveAppLink(''), isNull);
      expect(resolveAppLink('sslocal://lynxview?template.js'), isNull);
      expect(resolveAppLink('dragon1967://webview'), isNull);
      // 不是合法 URI 时不能抛。
      expect(resolveAppLink('http://[::1'), isNull);
    });

    test('stops instead of looping on a self-referencing link', () {
      // 每一跳都换成同构的下一跳，深度上限必须截断。
      final raw = Uri(
        scheme: 'dragon1967',
        host: 'webview',
        queryParameters: {
          'url': 'dragon1967://webview?url='
              'dragon1967%3A%2F%2Fwebview%3Furl%3D'
              'dragon1967%253A%252F%252Fwebview%253Furl%253D'
              'https%25253A%25252F%25252Fexample.com',
        },
      ).toString();

      // 四跳之后仍是自定义 scheme，说明深度上限生效了。
      expect(resolveAppLink(raw), isNull);
    });
  });
}
