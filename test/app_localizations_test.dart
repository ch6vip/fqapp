import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// issue #79：搜索框粘贴时系统文本菜单显示英文。
///
/// 原因是 MaterialApp 没有 `localizationsDelegates`，Flutter 只能回退到英文
/// 的 MaterialLocalizations——与系统语言无关。这组用例钉住两件事：配置还在
/// （防止回归），以及这套配置确实产出中文菜单文案。
void main() {
  test('main.dart keeps the Chinese localization wiring (#79)', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(
      source,
      contains('package:flutter_localizations/flutter_localizations.dart'),
      reason: '缺少 flutter_localizations 导入',
    );
    expect(
      source,
      contains('localizationsDelegates: GlobalMaterialLocalizations.delegates'),
      reason: '缺少 localizationsDelegates，Material 文案会回退英文',
    );
    expect(
      source,
      contains("locale: const Locale('zh', 'CN')"),
      reason: '界面文案全是中文，语言必须显式钉成中文',
    );
  });

  testWidgets('the Material text menu resolves to Chinese labels', (
    tester,
  ) async {
    late MaterialLocalizations localizations;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (context) {
            localizations = MaterialLocalizations.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(localizations.pasteButtonLabel, '粘贴');
    expect(localizations.copyButtonLabel, '复制');
    expect(localizations.selectAllButtonLabel, '全选');
  });
}
