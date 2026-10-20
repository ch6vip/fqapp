import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/reader/eink_image_provider.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets('EinkImageProvider 解出灰度抖动图且不报错', (tester) async {
    // 2x2 彩色图：红、绿、蓝、白。
    final image = img.Image(width: 2, height: 2);
    image.setPixelRgb(0, 0, 255, 0, 0);
    image.setPixelRgb(1, 0, 0, 255, 0);
    image.setPixelRgb(0, 1, 0, 0, 255);
    image.setPixelRgb(1, 1, 255, 255, 255);
    final bytes = img.encodePng(image);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Image(image: EinkImageProvider(MemoryImage(bytes))),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsOneWidget);
  });
}
