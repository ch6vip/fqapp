import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/reader_tap_zones.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('default zones match the historical tap behavior', () {
    expect(defaultReaderTapZones, hasLength(9));
    for (var row = 0; row < 3; row++) {
      expect(defaultReaderTapZones[row * 3], ReaderTapZoneAction.prevPage);
      expect(defaultReaderTapZones[row * 3 + 1], ReaderTapZoneAction.menu);
      expect(defaultReaderTapZones[row * 3 + 2], ReaderTapZoneAction.nextPage);
    }
  });

  test('one-hand preset turns both sides into next page', () {
    for (var row = 0; row < 3; row++) {
      expect(oneHandReaderTapZones[row * 3], ReaderTapZoneAction.nextPage);
      expect(oneHandReaderTapZones[row * 3 + 1], ReaderTapZoneAction.menu);
      expect(
        oneHandReaderTapZones[row * 3 + 2],
        ReaderTapZoneAction.nextPage,
      );
    }
  });

  test('fullscreen preset leaves only the center cell as menu', () {
    expect(fullscreenReaderTapZones, hasLength(9));
    for (var i = 0; i < 9; i++) {
      expect(
        fullscreenReaderTapZones[i],
        i == 4 ? ReaderTapZoneAction.menu : ReaderTapZoneAction.nextPage,
      );
    }
    // The preset already keeps a menu zone, so the guard leaves it as is.
    expect(
      ensureReaderTapZonesHaveMenu(fullscreenReaderTapZones),
      fullscreenReaderTapZones,
    );
  });

  test('tap position resolves to the 3x3 cell', () {
    const zones = defaultReaderTapZones;
    ReaderTapZoneAction at(double dx, double dy) =>
        readerTapZoneActionAt(
          zones: zones,
          dx: dx,
          dy: dy,
          width: 300,
          height: 600,
        );
    expect(at(10, 10), ReaderTapZoneAction.prevPage);
    expect(at(150, 300), ReaderTapZoneAction.menu);
    expect(at(290, 590), ReaderTapZoneAction.nextPage);
    expect(at(150, 10), ReaderTapZoneAction.menu);
    expect(at(10, 590), ReaderTapZoneAction.prevPage);
    // Out-of-range coordinates clamp to the edge cell.
    expect(at(-50, -50), ReaderTapZoneAction.prevPage);
    expect(at(9999, 9999), ReaderTapZoneAction.nextPage);
    // Degenerate size resolves to the center cell.
    expect(
      readerTapZoneActionAt(
        zones: zones,
        dx: 0,
        dy: 0,
        width: 0,
        height: 0,
      ),
      ReaderTapZoneAction.menu,
    );
  });

  test('malformed stored zones fall back to the default grid', () {
    expect(normalizeReaderTapZones(null), defaultReaderTapZones);
    expect(normalizeReaderTapZones(['nextPage']), defaultReaderTapZones);
    expect(
      normalizeReaderTapZones([
        'prevPage',
        'menu',
        'nextPage',
        'prevPage',
        'menu',
        'nextPage',
        'prevPage',
        'menu',
        'explode',
      ]),
      defaultReaderTapZones,
    );
  });

  test('at least one menu zone is always kept', () {
    final allNext = List<ReaderTapZoneAction>.filled(
      9,
      ReaderTapZoneAction.nextPage,
    );
    final fixed = ensureReaderTapZonesHaveMenu(allNext);
    expect(fixed[4], ReaderTapZoneAction.menu);
    expect(
      fixed.where((zone) => zone == ReaderTapZoneAction.menu),
      hasLength(1),
    );
    expect(
      ensureReaderTapZonesHaveMenu(defaultReaderTapZones),
      defaultReaderTapZones,
    );
  });

  test('tap zones round-trip through encode and preferences', () async {
    const zones = [
      ReaderTapZoneAction.toc,
      ReaderTapZoneAction.menu,
      ReaderTapZoneAction.nextChapter,
      ReaderTapZoneAction.prevChapter,
      ReaderTapZoneAction.menu,
      ReaderTapZoneAction.nextPage,
      ReaderTapZoneAction.none,
      ReaderTapZoneAction.menu,
      ReaderTapZoneAction.prevPage,
    ];
    await const ReaderPreferences(tapZones: zones).save();
    final restored = await ReaderPreferences.load();
    expect(restored.tapZones, zones);
    expect(
      encodeReaderTapZones(zones),
      [
        'toc',
        'menu',
        'nextChapter',
        'prevChapter',
        'menu',
        'nextPage',
        'none',
        'menu',
        'prevPage',
      ],
    );
  });

  test('legacy one-hand switch migrates to one-hand zones once', () async {
    SharedPreferences.setMockInitialValues({
      'reader_tap_left_turns_next': true,
    });
    expect(
      (await ReaderPreferences.load()).tapZones,
      oneHandReaderTapZones,
    );
    // After the first save the zones key exists, so the legacy switch no
    // longer re-applies: a user-edited grid is never overwritten.
    await (await ReaderPreferences.load())
        .copyWith(tapZones: defaultReaderTapZones)
        .save();
    SharedPreferences.setMockInitialValues({
      'reader_tap_left_turns_next': true,
      'reader_tap_zones': encodeReaderTapZones(defaultReaderTapZones),
    });
    expect(
      (await ReaderPreferences.load()).tapZones,
      defaultReaderTapZones,
    );
  });

  test('stored zones without a menu zone gain one in the center', () async {
    SharedPreferences.setMockInitialValues({
      'reader_tap_zones': List<String>.filled(9, 'nextPage'),
    });
    final restored = await ReaderPreferences.load();
    expect(restored.tapZones[4], ReaderTapZoneAction.menu);
  });
}
