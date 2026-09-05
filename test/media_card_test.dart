import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/media_card.dart';

void main() {
  testWidgets('cover size does not depend on title length', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final items = [
      _item('Short title'),
      _item('A title long enough to occupy both available lines'),
      _item('Another title', author: ''),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: mediaGridDelegate,
            itemCount: items.length,
            itemBuilder: (context, index) =>
                MediaCard(item: items[index], onTap: () {}),
          ),
        ),
      ),
    );

    final coverSizes = find
        .byType(AspectRatio)
        .evaluate()
        .map((element) => (element.renderObject! as RenderBox).size)
        .toList();

    expect(coverSizes, hasLength(items.length));
    for (final size in coverSizes) {
      expect(size, coverSizes.first);
      expect(size.width / size.height, closeTo(5 / 7, 0.001));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('adaptive grid accommodates accessibility text scaling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.5)),
          child: Builder(
            builder: (context) => Scaffold(
              body: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: mediaGridDelegateFor(context),
                itemCount: 3,
                itemBuilder: (_, index) => MediaCard(
                  item: _item('A long title that uses two complete lines'),
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}

MediaItem _item(String title, {String author = 'Author'}) => MediaItem(
  id: title,
  title: title,
  cover: '',
  author: author,
  badge: '',
  ep: '',
  kind: 'book',
);
