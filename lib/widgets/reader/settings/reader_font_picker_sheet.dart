import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/reader_device.dart';
import '../../../services/reader_preferences.dart';
import '../reader_theme.dart';
import 'reader_settings_widgets.dart';

/// 字体选择结果：空路径表示系统字体。
typedef ReaderFontSelection = ({String path, String name});

/// 小号字体选择器：系统字体 / 导入字体。导入失败的错误留在面板里显示。
Future<ReaderFontSelection?> showReaderFontPicker({
  required BuildContext context,
  required ReaderThemePreset preset,
  required String currentPath,
  required String currentName,
  required Future<ReaderFont?> Function() onPickFont,
}) {
  return showModalBottomSheet<ReaderFontSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => _ReaderFontPickerSheet(
      preset: preset,
      currentPath: currentPath,
      currentName: currentName,
      onPickFont: onPickFont,
    ),
  );
}

class _ReaderFontPickerSheet extends StatefulWidget {
  const _ReaderFontPickerSheet({
    required this.preset,
    required this.currentPath,
    required this.currentName,
    required this.onPickFont,
  });

  final ReaderThemePreset preset;
  final String currentPath;
  final String currentName;
  final Future<ReaderFont?> Function() onPickFont;

  @override
  State<_ReaderFontPickerSheet> createState() => _ReaderFontPickerSheetState();
}

class _ReaderFontPickerSheetState extends State<_ReaderFontPickerSheet> {
  bool _importing = false;
  String? _error;

  Future<void> _import() async {
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final font = await widget.onPickFont();
      if (!mounted || font == null) return;
      Navigator.pop(context, (path: font.path, name: font.name));
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is PlatformException
            ? error.message ?? '字体导入失败，请重新选择'
            : '无法载入字体，请选择有效的 TTF、OTF 或 TTC 文件',
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    final hasCustom = widget.currentPath.isNotEmpty;
    return ReaderSettingsSheetFrame(
      preset: widget.preset,
      title: '字体',
      closeTooltip: '关闭字体设置',
      scrollKey: const ValueKey('reader-font-scroll'),
      maxHeightFactor: 0.5,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ReaderSettingsChip(
                key: const ValueKey('reader-font-system'),
                label: '系统字体',
                selected: !hasCustom,
                onTap: () => Navigator.pop(context, (path: '', name: '')),
              ),
              ReaderSettingsChip(
                key: const ValueKey('reader-font-import'),
                label: '导入字体',
                selected: hasCustom,
                onTap: _importing ? null : _import,
              ),
            ],
          ),
        ),
        if (hasCustom)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '当前字体：${widget.currentName}',
              style: TextStyle(color: preset.mutedTextColor, fontSize: 12),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}
