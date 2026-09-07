import 'package:flutter/material.dart';

Future<int?> showReadingGoalDialog(BuildContext context, int current) {
  return showDialog<int>(
    context: context,
    builder: (_) => _ReadingGoalDialog(current: current),
  );
}

class _ReadingGoalDialog extends StatefulWidget {
  final int current;

  const _ReadingGoalDialog({required this.current});

  @override
  State<_ReadingGoalDialog> createState() => _ReadingGoalDialogState();
}

class _ReadingGoalDialogState extends State<_ReadingGoalDialog> {
  late final _controller = TextEditingController(text: '${widget.current}');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('每日阅读目标'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '分钟'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final minutes in [15, 30, 60, 120])
                ActionChip(
                  label: Text('$minutes 分钟'),
                  onPressed: () => Navigator.pop(context, minutes),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final value = int.tryParse(_controller.text) ?? widget.current;
            Navigator.pop(context, value.clamp(1, 1440));
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
