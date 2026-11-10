part of 'library_page.dart';

/// 收藏 tab 的 video/manju 类型筛选行。
///
/// 类型筛选是 fqapp 专有行为（官方收藏页按类型分频道），Key 与文案保持
/// 不变；视觉换成上游 `GlassTextButton` 选中态。
class _CollectionTypeFilter extends StatelessWidget {
  const _CollectionTypeFilter({
    required this.selected,
    required this.onChanged,
  });

  final String? selected;
  final ValueChanged<String?> onChanged;

  static const _options = <({String key, String label, String? value})>[
    (key: 'all', label: '全部', value: null),
    (key: 'video', label: '短剧', value: 'video'),
    (key: 'manju', label: '漫剧', value: 'manju'),
  ];

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final option in _options)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Semantics(
            key: Key('library-collection-filter-${option.key}'),
            selected: selected == option.value,
            inMutuallyExclusiveGroup: true,
            child: GlassTextButton(
              compact: true,
              selected: selected == option.value,
              onPressed: () => onChanged(option.value),
              child: AppText(option.label),
            ),
          ),
        ),
    ],
  );
}
