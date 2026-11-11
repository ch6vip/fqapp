import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/player/playlet_discussion_tile.dart';

/// 剧评 / 回复正文与阅读页段评共用同一套表情 token：方括号 token 必须渲染
/// 成官方表情图，而不是按字面显示。
void main() {
  testWidgets('renders bracket emoji tokens as images', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlayletDiscussionTile(
            text: '这段[笑]死我了',
            userName: '观众',
            userAvatar: '',
            published: '刚刚',
            diggCount: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image));
    expect(
      (image.image as AssetImage).assetName,
      'assets/images/emoji/emoji_03.webp',
    );
    expect(find.textContaining('[笑]'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
