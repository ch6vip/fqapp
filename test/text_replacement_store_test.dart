import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:fqapp/models/text_replacement_rule.dart';
import 'package:fqapp/services/text_replacement_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'failed write preserves published rules and does not notify listeners',
    () async {
      SharedPreferencesStorePlatform.instance = _FailingPreferences();
      final store = TextReplacementStore();
      await store.load();
      var notifications = 0;
      store.changes.addListener(() => notifications++);
      await expectLater(
        store.save(
          enabled: true,
          rules: [
            const TextReplacementRule(id: 'a', pattern: 'a', replacement: 'b'),
          ],
        ),
        throwsStateError,
      );
      expect(store.snapshot.enabled, isFalse);
      expect(store.snapshot.rules, isEmpty);
      expect(notifications, 0);
    },
  );
  test('missing preferences leave replacement disabled', () async {
    final store = TextReplacementStore();
    await store.load();
    expect(store.snapshot.enabled, isFalse);
    expect(store.snapshot.rules, isEmpty);
  });
  test('saves rule order and publishes only after persistence', () async {
    final store = TextReplacementStore();
    await store.load();
    final rules = [
      const TextReplacementRule(id: 'b', pattern: '漂亮国', replacement: '美国'),
      const TextReplacementRule(
        id: 'a',
        pattern: '美国',
        replacement: 'US',
        enabled: false,
      ),
    ];
    await store.save(enabled: true, rules: rules);
    final restored = TextReplacementStore();
    await restored.load();
    expect(restored.snapshot.enabled, isTrue);
    expect(restored.snapshot.rules.map((r) => r.id), ['b', 'a']);
    expect(restored.snapshot.rules.last.enabled, isFalse);
    expect(store.snapshot.revision, 1);
  });
  test('skips malformed records without rewriting saved content', () async {
    final raw = jsonEncode({
      'schemaVersion': 1,
      'enabled': true,
      'rules': [
        {'id': 'bad', 'pattern': 42},
        {
          'id': 'good',
          'pattern': 'a',
          'replacement': 'b',
          'enabled': true,
          'isRegex': false,
        },
      ],
    });
    SharedPreferences.setMockInitialValues({'reader_text_replacement_v1': raw});
    final store = TextReplacementStore();
    await store.load();
    expect(store.snapshot.rules.single.id, 'good');
    expect(store.warning, isNotNull);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'reader_text_replacement_v1',
      ),
      raw,
    );
  });
  test(
    'rejects empty patterns, duplicate ids, line breaks and oversized rules',
    () async {
      final store = TextReplacementStore();
      await store.load();
      for (final rule in [
        const TextReplacementRule(id: 'a', pattern: '', replacement: ''),
        const TextReplacementRule(id: 'a', pattern: 'a', replacement: 'b\nc'),
        TextReplacementRule(id: 'a', pattern: 'a' * 2049, replacement: ''),
      ]) {
        await expectLater(
          store.save(enabled: true, rules: [rule]),
          throwsFormatException,
        );
      }
      const rule = TextReplacementRule(id: 'a', pattern: 'a', replacement: '');
      await expectLater(
        store.save(enabled: true, rules: [rule, rule]),
        throwsFormatException,
      );
      expect(store.snapshot.rules, isEmpty);
      expect(store.snapshot.revision, 0);
    },
  );
}

class _FailingPreferences extends InMemorySharedPreferencesStore {
  _FailingPreferences() : super.empty();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}
