import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/legacy_ui_notice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'only legacy archive users with local data get the one-time notice',
    () async {
      Future<bool> show(
        Map<String, Object> values, {
        bool data = true,
        AppThemeStyle style = AppThemeStyle.archive,
      }) async {
        SharedPreferences.setMockInitialValues(values);
        return LegacyUiNotice.shouldShow(
          preferences: SharedPreferences.getInstance,
          hasLocalData: data,
          style: style,
        );
      }

      expect(await show({}), isTrue);
      expect(await show({}, data: false), isFalse);
      expect(await show({}, style: AppThemeStyle.classic), isFalse);
      expect(await show({LegacyUiNotice.seenKey: true}), isFalse);
      expect(await show({AppThemeStyleStore.storageKey: 'classic'}), isFalse);
    },
  );

  test('a fresh install is marked skipped before it adds data', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await LegacyUiNotice.shouldShow(
      preferences: SharedPreferences.getInstance,
      hasLocalData: false,
      style: AppThemeStyle.archive,
    );
    expect(first, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(LegacyUiNotice.seenKey), isTrue);
    final afterAddingData = await LegacyUiNotice.shouldShow(
      preferences: SharedPreferences.getInstance,
      hasLocalData: true,
      style: AppThemeStyle.archive,
    );
    expect(afterAddingData, isFalse);
  });

  test('an unavailable store neither shows nor marks the notice', () async {
    SharedPreferences.setMockInitialValues({});
    final shown = await LegacyUiNotice.shouldShow(
      preferences: SharedPreferences.getInstance,
      style: AppThemeStyle.archive,
    );
    expect(shown, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(LegacyUiNotice.seenKey), isNull);
  });

  test('markSeen persists the one-time flag', () async {
    SharedPreferences.setMockInitialValues({});
    await LegacyUiNotice.markSeen(preferences: SharedPreferences.getInstance);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(LegacyUiNotice.seenKey), isTrue);
  });
}
