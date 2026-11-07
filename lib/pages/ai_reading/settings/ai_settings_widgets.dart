import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';

/// Shared formatting and small dialogs for the AI reading settings pages.
/// Visual tokens stay in [HomePalette]; nothing here introduces new colours.

String aiFormatTokens(int value) {
  if (value >= 100000000) {
    return '${(value / 100000000).toStringAsFixed(2)} 亿';
  }
  if (value >= 10000) {
    final text = value / 10000;
    return '${text.toStringAsFixed(text >= 100 ? 0 : 1)} 万';
  }
  return '$value';
}

String aiCurrencySymbol(String currency) => switch (currency) {
  'USD' => r'$',
  'EUR' => '€',
  'JPY' => 'JP¥',
  _ => '¥',
};

String aiFormatCostMicros(int micros, String currency) {
  final symbol = aiCurrencySymbol(currency);
  if (micros <= 0) return '${symbol}0.00';
  final units = micros / 1000000;
  final digits = units < 0.01 ? 4 : 2;
  return '$symbol${units.toStringAsFixed(digits)}';
}

String aiFormatPercent(double ratio) {
  if (!ratio.isFinite) return '—';
  return '${(ratio * 100).round()}%';
}

String _two(int value) => value.toString().padLeft(2, '0');

String aiFormatDateTime(DateTime time) =>
    '${_two(time.month)}-${_two(time.day)} ${_two(time.hour)}:${_two(time.minute)}';

String aiFormatDate(DateTime time) =>
    '${time.year}-${_two(time.month)}-${_two(time.day)}';

String aiSourceLabel(String? source) => switch (source) {
  'book' => '本书',
  'global' => '全局',
  'builtin' => '内置',
  _ => '未知',
};

Widget aiSourcePill(String? source) => AiStatusPill(
  label: aiSourceLabel(source),
  tone: switch (source) {
    'book' => AiStatusTone.ok,
    'global' => AiStatusTone.warn,
    _ => AiStatusTone.neutral,
  },
);

/// Source pill followed by the usual navigation chevron, for [SettingsRow]
/// trailing slots where a custom widget replaces the built-in chevron.
Widget aiSourceTrailing(BuildContext context, String? source) {
  final palette = HomePalette.of(context);
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      aiSourcePill(source),
      const SizedBox(width: 4),
      Icon(Icons.chevron_right, size: 18, color: palette.muted),
    ],
  );
}

void aiShowSnack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

/// Integer editor used for token and request limits. Returns null on cancel.
Future<int?> showAiIntDialog(
  BuildContext context, {
  required String title,
  required String label,
  int? initial,
  int min = 0,
  int max = 1000000000,
  String? helper,
}) async {
  final controller = TextEditingController(text: initial?.toString() ?? '');
  final result = await showDialog<int>(
    context: context,
    builder: (dialogContext) {
      final palette = HomePalette.of(dialogContext);
      String? error;
      return StatefulBuilder(
        builder: (dialogContext, setState) {
          void submit() {
            final parsed = int.tryParse(controller.text.trim());
            if (parsed == null) {
              setState(() => error = '请输入整数');
              return;
            }
            if (parsed < min || parsed > max) {
              setState(() => error = '请输入 $min 到 $max 之间的数字');
              return;
            }
            Navigator.pop(dialogContext, parsed);
          }

          return AlertDialog(
            backgroundColor: palette.surface,
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: label,
                helperText: helper,
                errorText: error,
              ),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('保存')),
            ],
          );
        },
      );
    },
  );
  controller.dispose();
  return result;
}

/// One form for the two integer limits. The old flow asked for tokens and
/// requests in two consecutive dialogs, which felt like the save had failed.
Future<({int tokens, int requests})?> showAiLimitDialog(
  BuildContext context, {
  required String title,
  required int tokenInitial,
  required int requestInitial,
  String tokenLabel = 'Token 上限',
  String requestLabel = '请求次数上限',
  String? helper,
  int tokenMin = 1,
  int tokenMax = 1000000000,
  int requestMin = 1,
  int requestMax = 100000,
}) async {
  final token = TextEditingController(text: tokenInitial.toString());
  final request = TextEditingController(text: requestInitial.toString());
  final result = await showDialog<({int tokens, int requests})>(
    context: context,
    builder: (dialogContext) {
      final palette = HomePalette.of(dialogContext);
      String? tokenError;
      String? requestError;
      return StatefulBuilder(
        builder: (dialogContext, setState) {
          void submit() {
            final tokens = int.tryParse(token.text.trim());
            final requests = int.tryParse(request.text.trim());
            setState(() {
              tokenError = tokens == null
                  ? '请输入整数'
                  : tokens < tokenMin || tokens > tokenMax
                  ? '请输入 $tokenMin 到 $tokenMax 之间的数字'
                  : null;
              requestError = requests == null
                  ? '请输入整数'
                  : requests < requestMin || requests > requestMax
                  ? '请输入 $requestMin 到 $requestMax 之间的数字'
                  : null;
            });
            if (tokenError != null || requestError != null) return;
            Navigator.pop(dialogContext, (
              tokens: tokens!,
              requests: requests!,
            ));
          }

          return AlertDialog(
            backgroundColor: palette.surface,
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: token,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: tokenLabel,
                    helperText: helper,
                    errorText: tokenError,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: request,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: requestLabel,
                    errorText: requestError,
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('保存')),
            ],
          );
        },
      );
    },
  );
  token.dispose();
  request.dispose();
  return result;
}

/// Cost editor. An empty field clears the limit, so the result carries both a
/// `saved` flag and the nullable value.
Future<({bool saved, double? value})> showAiCostDialog(
  BuildContext context, {
  required String title,
  required String label,
  required String currency,
  double? initial,
  String? helper,
}) async {
  final controller = TextEditingController(
    text: initial == null ? '' : initial.toString(),
  );
  final result = await showDialog<({bool saved, double? value})>(
    context: context,
    builder: (dialogContext) {
      final palette = HomePalette.of(dialogContext);
      String? error;
      return StatefulBuilder(
        builder: (dialogContext, setState) {
          void submit() {
            final text = controller.text.trim();
            if (text.isEmpty) {
              Navigator.pop(dialogContext, (saved: true, value: null));
              return;
            }
            final parsed = double.tryParse(text);
            if (parsed == null || !parsed.isFinite || parsed < 0) {
              setState(() => error = '请输入不小于 0 的数字，留空表示不限额');
              return;
            }
            Navigator.pop(dialogContext, (saved: true, value: parsed));
          }

          return AlertDialog(
            backgroundColor: palette.surface,
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: label,
                prefixText: '$currency ',
                helperText: helper ?? '留空表示不设置费用上限',
                errorText: error,
              ),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, (saved: false, value: null)),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('保存')),
            ],
          );
        },
      );
    },
  );
  controller.dispose();
  return result ?? (saved: false, value: null);
}

/// Obscured single-line input for API keys. The stored value is never
/// pre-filled or shown again.
Future<String?> showAiSecretDialog(
  BuildContext context, {
  required String title,
  String? hint,
  String? helper,
}) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      final palette = HomePalette.of(dialogContext);
      return AlertDialog(
        backgroundColor: palette.surface,
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(hintText: hint, helperText: helper),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      );
    },
  );
  controller.dispose();
  return result;
}

/// Simple single-choice dialog. Returns the chosen key, or null on cancel.
Future<String?> showAiChoiceDialog(
  BuildContext context, {
  required String title,
  required List<({String key, String label, bool selected})> options,
  String? message,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      final palette = HomePalette.of(dialogContext);
      return SimpleDialog(
        backgroundColor: palette.surface,
        title: Text(title),
        children: [
          if (message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: palette.muted,
                ),
              ),
            ),
          for (final option in options)
            ListTile(
              title: Text(option.label),
              trailing: option.selected
                  ? Icon(Icons.check, size: 18, color: palette.ink)
                  : null,
              onTap: () => Navigator.pop(dialogContext, option.key),
            ),
        ],
      );
    },
  );
}

/// Sampling temperature editor. `allowInherit` adds a book-level "follow
/// global" action; the returned record tells the caller whether to clear the
/// override.
Future<({bool inherit, double value})?> showAiTemperatureDialog(
  BuildContext context, {
  required double initial,
  bool allowInherit = false,
}) async {
  var value = initial.clamp(0.0, 2.0);
  return showDialog<({bool inherit, double value})>(
    context: context,
    builder: (dialogContext) {
      final palette = HomePalette.of(dialogContext);
      return StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          backgroundColor: palette.surface,
          title: const Text('温度'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
              Slider(
                value: value,
                min: 0,
                max: 2,
                divisions: 20,
                label: value.toStringAsFixed(1),
                onChanged: (next) => setState(() => value = next),
              ),
              Text(
                '越低越稳定，越高越发散。思考模式开启时，'
                '部分服务商会忽略温度。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: palette.muted,
                ),
              ),
            ],
          ),
          actions: [
            if (allowInherit)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, (
                  inherit: true,
                  value: initial,
                )),
                child: const Text('跟随全局'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, (inherit: false, value: value)),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    },
  );
}
