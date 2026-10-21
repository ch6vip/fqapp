import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/lan_share_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// LAN sharing widens the listener from loopback to every interface, so the
/// default must stay off and the choice must survive a restart.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LanSharePreferences.instance.resetForTest();
  });

  tearDown(() => LanSharePreferences.instance.resetForTest());

  test('sharing is off before anything is read', () {
    expect(LanSharePreferences.instance.enabled.value, isFalse);
  });

  test('a missing key loads as off', () async {
    await LanSharePreferences.instance.load();
    expect(LanSharePreferences.instance.enabled.value, isFalse);
  });

  test('setEnabled persists across a reload', () async {
    await LanSharePreferences.instance.setEnabled(true);
    expect(LanSharePreferences.instance.enabled.value, isTrue);

    // A fresh process reads the stored value rather than the default.
    LanSharePreferences.instance.resetForTest();
    expect(LanSharePreferences.instance.enabled.value, isFalse);
    await LanSharePreferences.instance.load();
    expect(LanSharePreferences.instance.enabled.value, isTrue);
  });

  test('load picks up a value written earlier', () async {
    SharedPreferences.setMockInitialValues({
      LanSharePreferences.key: true,
    });
    await LanSharePreferences.instance.load();
    expect(LanSharePreferences.instance.enabled.value, isTrue);
  });

  test('turning sharing off persists too', () async {
    await LanSharePreferences.instance.setEnabled(true);
    await LanSharePreferences.instance.setEnabled(false);

    LanSharePreferences.instance.resetForTest();
    await LanSharePreferences.instance.load();
    expect(LanSharePreferences.instance.enabled.value, isFalse);
  });
}
