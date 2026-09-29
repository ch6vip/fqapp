import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/short_series_font_scale.dart';

/// 官方短剧字号档（jm3.t0/nm3.e/jk3）的服务用例：三档系数、档位文案、
/// SP 持久化与越界钳制。
void main() {
  tearDown(() => ShortSeriesFontScale.instance = 0);

  test('三档系数与文案对齐官方 eh3/c 与 jk3/a', () {
    expect(ShortSeriesFontScale.factors, [1.0, 1.15, 1.3]);
    expect(ShortSeriesFontScale.labels, ['标准', '大号', '超大号']);
    // 默认档：官方 current_selected_index 缺省 0。
    expect(ShortSeriesFontScale.instance, 0);
    expect(ShortSeriesFontScale.scale, 1.0);
    expect(ShortSeriesFontScale.label, '标准');
  });

  test('save 同步生效并写入官方 SP 键', () async {
    SharedPreferences.setMockInitialValues({});
    await ShortSeriesFontScale.save(2);
    expect(ShortSeriesFontScale.instance, 2);
    expect(ShortSeriesFontScale.scale, 1.3);
    expect(ShortSeriesFontScale.label, '超大号');
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt('short_series_font_scale_manager/current_selected_index'),
      2,
    );
  });

  test('save 越界档位钳制到合法区间', () async {
    SharedPreferences.setMockInitialValues({});
    await ShortSeriesFontScale.save(9);
    expect(ShortSeriesFontScale.instance, 2);
    await ShortSeriesFontScale.save(-1);
    expect(ShortSeriesFontScale.instance, 0);
  });

  test('load 恢复持久化档位，缺省与越界都回到合法档', () async {
    SharedPreferences.setMockInitialValues({
      'short_series_font_scale_manager/current_selected_index': 1,
    });
    await ShortSeriesFontScale.load();
    expect(ShortSeriesFontScale.instance, 1);

    SharedPreferences.setMockInitialValues({});
    await ShortSeriesFontScale.load();
    expect(ShortSeriesFontScale.instance, 0);

    // 手工改过 SP 或上游改版出现越界值时宁回标准档，不给崩。
    SharedPreferences.setMockInitialValues({
      'short_series_font_scale_manager/current_selected_index': 7,
    });
    await ShortSeriesFontScale.load();
    expect(ShortSeriesFontScale.instance, 2);
  });
}
