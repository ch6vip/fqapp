import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/book_comment.dart';
import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/widgets/detail/detail_reviews.dart';
import 'package:fqapp/widgets/player/playlet_reply_panel.dart';
import 'package:fqapp/widgets/reader/reader_illustration.dart';

CommentReply? imageReply({String text = ''}) => CommentReply.fromRaw({
  'reply_id': 'image-reply',
  'Common': {
    'content': {
      'text': text,
      'image_data_list': {
        'image_data': [
          {'web_url': 'https://example.test/reply.jpg'},
          {'web_url': 'file:///invalid.jpg'},
        ],
      },
    },
  },
});

void main() {
  test('keeps image-only replies and validates their URLs', () {
    final reply = imageReply();
    expect(reply, isNotNull);
    expect(reply!.isEmpty, isFalse);
    expect(reply.imageUrls, ['https://example.test/reply.jpg']);
  });

  testWidgets('book review replies display attached images', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DetailCommentTile(
            comment: const BookComment(id: 'parent', text: '书评', replyCount: 1),
            replyLoader: (_) async => CommentReplyPage(
              replies: [imageReply(text: '配图回复')!],
              totalCount: 1,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('detail_reply_toggle_parent')));
    await tester.pumpAndSettle();
    expect(find.text('配图回复'), findsOneWidget);
    expect(find.byType(ReaderIllustration), findsOneWidget);
  });

  testWidgets(
    'playlet replies also display images from the shared reply model',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayletReplyPanel(
              seriesId: 'series',
              comment: const PlayletComment(id: 'parent', text: '剧评'),
              onBack: () {},
              loader:
                  ({
                    required commentId,
                    required count,
                    required cursor,
                    String refReplyId = '',
                  }) async => CommentReplyPage(
                    replies: [imageReply(text: '配图回复')!],
                    totalCount: 1,
                  ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('配图回复'), findsOneWidget);
      expect(find.byType(ReaderIllustration), findsOneWidget);
    },
  );
}
