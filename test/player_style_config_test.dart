import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/player_style_config.dart';

/// 官方播放页开关的解析用例。
///
/// 键名与官方服务端配置一致（见
/// .agents/notes/proposed/architecture/2026-09-25-f01-f03-official-evidence.md §1）：
/// `PlayerBottomStyleConfig.a()` 是「或」，`func_reverse_of_clear_screen_v691`
/// 与 `landscape_func_config_v705` 各自独立，默认全部关闭。
void main() {
  tearDown(() => PlayerStyleConfig.instance = PlayerStyleConfig.defaults);

  test('defaults match the official shipped defaults', () {
    const config = PlayerStyleConfig.defaults;
    // 官方 `PlayerBottomStyleConfig()` 默认 (false, false)，但本仓库发布的
    // config.json 显式打开新底栏；默认常量本身按官方类走。
    expect(config.useNewPlayerBottomStyle, isFalse);
    expect(config.hasBanner, isFalse);
    expect(config.padNewBottomStyle, isFalse);
    expect(config.reverseClearScreen, isFalse);
    expect(config.landscapeLockEnabled, isFalse);
  });

  test('the bottom style is an OR of both fields', () {
    expect(const PlayerStyleConfig().newBottomStyle, isFalse);
    expect(
      const PlayerStyleConfig(
        useNewPlayerBottomStyle: false,
        hasBanner: true,
      ).newBottomStyle,
      isTrue,
    );
    expect(
      const PlayerStyleConfig(useNewPlayerBottomStyle: true).newBottomStyle,
      isTrue,
    );
  });

  test('parses the official keys out of config.json', () {
    final config = PlayerStyleConfig.fromJson({
      'player_bottom_style_config': {
        'use_new_player_bottom_style': true,
        'has_banner': false,
      },
      'func_reverse_of_clear_screen_v691': {'reverse': true},
      'landscape_func_config_v705': {'enable_lock': true},
      'pad_new_player_bottom_style': true,
    });
    expect(config.useNewPlayerBottomStyle, isTrue);
    expect(config.hasBanner, isFalse);
    expect(config.reverseClearScreen, isTrue);
    expect(config.landscapeLockEnabled, isTrue);
    expect(config.padNewBottomStyle, isTrue);
  });

  test('a missing section keeps every switch off', () {
    final config = PlayerStyleConfig.fromJson({'port': 8080});
    expect(config.useNewPlayerBottomStyle, isFalse);
    expect(config.reverseClearScreen, isFalse);
    expect(config.landscapeLockEnabled, isFalse);
  });

  test(
    'load reads the bundled config and survives a malformed bundle',
    () async {
      final loaded = await PlayerStyleConfig.load(
        bundle: _StringBundle('''
{
  "player_bottom_style_config": {"use_new_player_bottom_style": true},
  "landscape_func_config_v705": {"enable_lock": true}
}
'''),
      );
      expect(loaded.useNewPlayerBottomStyle, isTrue);
      expect(loaded.landscapeLockEnabled, isTrue);
      expect(PlayerStyleConfig.instance.landscapeLockEnabled, isTrue);

      PlayerStyleConfig.instance = PlayerStyleConfig.defaults;
      final broken = await PlayerStyleConfig.load(
        bundle: _StringBundle('not json at all'),
      );
      expect(broken, same(PlayerStyleConfig.defaults));
      expect(PlayerStyleConfig.instance.landscapeLockEnabled, isFalse);
    },
  );
}

class _StringBundle extends CachingAssetBundle {
  _StringBundle(this.contents);

  final String contents;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(contents.codeUnits));
}
