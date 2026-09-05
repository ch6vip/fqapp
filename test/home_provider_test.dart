import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';

void main() {
  test('a late response cannot overwrite or populate another tab', () async {
    final requests = <int, List<Completer<HomepagePage>>>{};

    Future<HomepagePage> loadHomepage({
      int tabType = 2,
      int offset = 0,
      String? sessionId,
    }) {
      final completer = Completer<HomepagePage>();
      requests.putIfAbsent(tabType, () => []).add(completer);
      return completer.future;
    }

    Future<List<SearchTab>> loadSearch(String query, {int page = 1}) async =>
        const [];

    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () =>
          HomeNotifier(homepageLoader: loadHomepage, searchLoader: loadSearch),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);

    notifier.selectTab(1); // 小说, request still pending.
    expect(requests[2], hasLength(1));
    notifier.selectTab(2); // 短剧 supersedes it.
    expect(requests[8], hasLength(1));

    requests[8]!.single.complete(
      HomepagePage(items: [_item('video')], nextOffset: null, sessionId: null),
    );
    await _flushMicrotasks();
    expect(container.read(provider).tabIndex, 2);
    expect(container.read(provider).items.single.id, 'video');
    expect(container.read(provider).items.single.kind, 'video');

    // Completing the older novel request must not change the selected feed.
    requests[2]!.single.complete(
      HomepagePage(
        items: [_item('stale-book')],
        nextOffset: null,
        sessionId: null,
      ),
    );
    await _flushMicrotasks();
    expect(container.read(provider).tabIndex, 2);
    expect(container.read(provider).items.single.id, 'video');

    // The canceled novel request must not make an empty cache look loaded.
    notifier.selectTab(1);
    expect(requests[2], hasLength(2));
    requests[2]!.last.complete(
      HomepagePage(
        items: [_item('fresh-book')],
        nextOffset: null,
        sessionId: null,
      ),
    );
    await _flushMicrotasks();
    expect(container.read(provider).items.single.id, 'fresh-book');
    expect(container.read(provider).items.single.kind, 'book');
  });
}

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);
