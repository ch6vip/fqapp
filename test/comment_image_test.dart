import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/comment_image.dart';

void main() {
  test('keeps HTTP image URLs in order and rejects malformed entries', () {
    final images = parseCommentImageUrls([
      ' https://example.test/first.jpg ',
      {'web_url': 'http://example.test/second.jpg'},
      {'web_url': 42},
      null,
      {},
      '',
      'file:///private/image.jpg',
      'data:image/png;base64,AA',
      'https:///image.jpg',
    ]);
    expect(images, [
      'https://example.test/first.jpg',
      'http://example.test/second.jpg',
    ]);
    expect(() => images.add('other'), throwsUnsupportedError);
    expect(parseCommentImageUrls(null), isEmpty);
    expect(parseCommentImageUrls({'image': 'wrong-shape'}), isEmpty);
  });
}
