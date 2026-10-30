import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/comment_emoji.dart';

void main() {
  group('commentEmojiSpans', () {
    test('splits plain text from a known token', () {
      final spans = commentEmojiSpans('你好[微笑]', fontSize: 16);

      expect(spans, hasLength(2));
      expect((spans[0] as TextSpan).text, '你好');
      final emoji = spans[1] as WidgetSpan;
      expect(emoji.alignment, PlaceholderAlignment.middle);
      final image = emoji.child as Image;
      expect(
        (image.image as AssetImage).assetName,
        'assets/images/emoji/emoji_01.webp',
      );
      expect(image.width, closeTo(22.4, 0.001));
      expect(image.height, closeTo(22.4, 0.001));
    });

    test('keeps unknown tokens and surrounding text literal', () {
      final spans = commentEmojiSpans('前[不存在的表情]后', fontSize: 13.5);

      expect(spans, hasLength(3));
      expect((spans[0] as TextSpan).text, '前');
      expect((spans[1] as TextSpan).text, '[不存在的表情]');
      expect((spans[2] as TextSpan).text, '后');
    });

    test('matches the official ASCII and Chinese token forms', () {
      expect(commentEmojiPattern.hasMatch('[OK]'), isTrue);
      expect(commentEmojiPattern.hasMatch('[书架加一]'), isTrue);
      expect(commentEmojiPattern.hasMatch('[ok]'), isFalse);
      expect(commentEmojiPattern.hasMatch('[微笑'), isFalse);
    });
  });

  group('CommentEmojiText', () {
    testWidgets('keeps a token-free body as plain Text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CommentEmojiText(
              text: '没有表情',
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );

      expect(find.text('没有表情'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('renders a token as an inline image', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CommentEmojiText(
              text: '[微笑]',
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('[微笑]'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
