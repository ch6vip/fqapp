import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/comment_images.dart';
import 'package:fqapp/widgets/reader/reader_illustration.dart';

/// Comment attachments render at most at 144×180dp (#266): decoding them at
/// the chapter-illustration cap of 2048×4096 spends ~33 MiB per bitmap on a
/// comment list, which is what an 8 GiB device cannot afford.
void main() {
  testWidgets('comment attachments use the thumbnail decode cap', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CommentImages(
            imageUrls: [
              'https://example.test/one.jpg',
              'https://example.test/two.jpg',
            ],
          ),
        ),
      ),
    );

    final tiles = tester
        .widgetList<ReaderIllustration>(find.byType(ReaderIllustration))
        .toList();
    expect(tiles, hasLength(2));
    for (final tile in tiles) {
      expect(tile.maxDecodeWidth, CommentImages.maxDecodeWidth);
      expect(tile.maxDecodeHeight, CommentImages.maxDecodeHeight);
    }
  });

  test('the cap still covers a 3× display for the single-image box', () {
    // 144×180dp at 3× is 432×540.
    expect(CommentImages.maxDecodeWidth, greaterThanOrEqualTo(432));
    expect(CommentImages.maxDecodeHeight, greaterThanOrEqualTo(540));
  });
}
