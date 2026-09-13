import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/search_discovery.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/widgets/detail/detail_description.dart';
import 'package:fqapp/widgets/detail/detail_sections.dart';
import 'package:fqapp/widgets/search/search_discovery.dart';

void main() {
  testWidgets('highlighted search suggestions honor the ambient text scaler', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: Scaffold(
          body: SearchSuggestionList(
            suggestions: const [
              SearchSuggestion(text: 'hello', highlighted: '<em>he</em>llo'),
            ],
            onSelect: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    final rich = tester.widget<RichText>(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == 'hello',
      ),
    );
    expect(rich.textScaler.scale(14), 28);
    expect(tester.takeException(), isNull);
  });

  testWidgets('description measurement merges the ambient text style', (
    tester,
  ) async {
    const width = 300.0;
    const base = TextStyle(fontSize: 13.5, height: 1.85);
    const ambient = TextStyle(letterSpacing: 6);
    String? longText;
    for (var length = 1; length <= 400; length++) {
      final candidate = List.filled(length, 'a').join();
      final plain = TextPainter(
        text: TextSpan(text: candidate, style: base),
        textDirection: TextDirection.ltr,
        maxLines: 3,
      )..layout(maxWidth: width);
      final plainFits = !plain.didExceedMaxLines;
      plain.dispose();

      final styled = TextPainter(
        text: TextSpan(text: candidate, style: ambient.merge(base)),
        textDirection: TextDirection.ltr,
        maxLines: 3,
      )..layout(maxWidth: width);
      final styledExceeds = styled.didExceedMaxLines;
      styled.dispose();

      if (plainFits && styledExceeds) {
        longText = candidate;
        break;
      }
    }
    expect(longText, isNotNull);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DefaultTextStyle(
            style: ambient,
            child: Center(
              child: SizedBox(
                width: width,
                child: DetailDescription(text: longText!),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('detail_description_toggle')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cast row grows with accessibility text scaling', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: DetailCastRow(
                cast: [CastMember(actor: 'Actor', role: 'Role')],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const Key('detail_cast_row'))).height,
      greaterThan(118),
    );
  });
}
