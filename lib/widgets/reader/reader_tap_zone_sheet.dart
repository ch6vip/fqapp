import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/reader_preferences.dart';
import '../../services/reader_tap_zones.dart';
import 'reader_theme.dart';

/// 点击区域设置编辑器：全屏半透明弹窗里的 3x3 九宫格，布局参考 Legado 的
/// “点击区域设置”（每格显示当前动作，点格换动作），实现为 fqapp 自己的代码。
///
/// 返回新的九宫格；点 X 或点遮罩关闭时返回 null（不保存）。
Future<List<ReaderTapZoneAction>?> showReaderTapZoneEditor({
  required BuildContext context,
  required List<ReaderTapZoneAction> initialZones,
  ReaderThemePreset preset = ReaderThemePreset.light,
}) {
  return showDialog<List<ReaderTapZoneAction>>(
    context: context,
    barrierColor: Colors.black54,
    barrierDismissible: true,
    builder: (context) =>
        _ReaderTapZoneEditor(initialZones: initialZones, preset: preset),
  );
}

class _ReaderTapZoneEditor extends StatefulWidget {
  const _ReaderTapZoneEditor({
    required this.initialZones,
    required this.preset,
  });

  final List<ReaderTapZoneAction> initialZones;
  final ReaderThemePreset preset;

  @override
  State<_ReaderTapZoneEditor> createState() => _ReaderTapZoneEditorState();
}

class _ReaderTapZoneEditorState extends State<_ReaderTapZoneEditor> {
  late List<ReaderTapZoneAction> _zones = normalizeReaderTapZones(
    widget.initialZones,
  );

  Future<void> _pickAction(int index) async {
    final preset = widget.preset;
    final selected = await showModalBottomSheet<ReaderTapZoneAction>(
      context: context,
      backgroundColor: preset.panelColor,
      builder: (context) => Theme(
        data: preset.theme(Theme.of(context)),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('选择动作'), enabled: false),
              for (final action in ReaderTapZoneAction.values)
                ListTile(
                  title: Text(action.label),
                  trailing: action == _zones[index]
                      ? Icon(LucideIcons.check, color: preset.accentColor)
                      : null,
                  onTap: () => Navigator.pop(context, action),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => _zones[index] = selected);
    }
  }

  void _applyPreset(List<ReaderTapZoneAction> preset) {
    setState(() => _zones = List<ReaderTapZoneAction>.of(preset));
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final hasMenu = _zones.contains(ReaderTapZoneAction.menu);
    return Dialog(
      backgroundColor: preset.sheetColor,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Theme(
        data: preset.theme(Theme.of(context)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '点击区域设置',
                      style: TextStyle(
                        color: preset.textColor,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: Icon(LucideIcons.x, color: preset.textColor),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Column(
                  children: [
                    for (var row = 0; row < 3; row++)
                      Expanded(
                        child: Row(
                          children: [
                            for (var column = 0; column < 3; column++)
                              Expanded(
                                child: _ZoneCell(
                                  label: _zones[row * 3 + column].label,
                                  preset: preset,
                                  onTap: () => _pickAction(row * 3 + column),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _PresetButtons(preset: preset, onApplyPreset: _applyPreset),
              const SizedBox(height: 8),
              Text(
                hasMenu ? '点九宫格换动作；至少保留一个菜单区域' : '没有菜单区域，完成时中间自动恢复为菜单',
                style: TextStyle(color: preset.mutedTextColor, fontSize: 13),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    ensureReaderTapZonesHaveMenu(_zones),
                  ),
                  child: const Text('完成'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 预设按钮行：默认 / 单手模式 / 全屏翻页，一键套用整套九宫格。
class _PresetButtons extends StatelessWidget {
  const _PresetButtons({required this.onApplyPreset, required this.preset});

  final ValueChanged<List<ReaderTapZoneAction>> onApplyPreset;
  final ReaderThemePreset preset;

  Widget _button(String label, List<ReaderTapZoneAction> zones) {
    return Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: preset.textColor,
          side: BorderSide(color: preset.borderColor),
        ),
        onPressed: () => onApplyPreset(zones),
        child: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _button('默认', defaultReaderTapZones),
        const SizedBox(width: 12),
        _button('单手模式', oneHandReaderTapZones),
        const SizedBox(width: 12),
        _button('全屏翻页', fullscreenReaderTapZones),
      ],
    );
  }
}

class _ZoneCell extends StatelessWidget {
  const _ZoneCell({
    required this.label,
    required this.onTap,
    required this.preset,
  });

  final String label;
  final VoidCallback onTap;
  final ReaderThemePreset preset;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: preset.fieldColor,
          border: Border.all(color: preset.borderColor),
        ),
        child: Text(
          label,
          style: TextStyle(color: preset.textColor, fontSize: 18),
        ),
      ),
    );
  }
}
