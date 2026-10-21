import 'package:flutter/material.dart';
import '../pages/settings_category_page.dart';

class DesktopSettingsBody extends StatefulWidget {
  const DesktopSettingsBody({super.key, required this.categories});
  final List<SettingsCategory> categories;
  @override
  State<DesktopSettingsBody> createState() => _DesktopSettingsBodyState();
}

class _DesktopSettingsBodyState extends State<DesktopSettingsBody> {
  int _selected = 0;
  @override
  Widget build(BuildContext context) {
    final category = widget.categories[_selected];
    return Row(
      children: [
        SizedBox(
          width: 248,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (var i = 0; i < widget.categories.length; i++)
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  selected: _selected == i,
                  selectedTileColor: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: .1),
                  leading: Icon(widget.categories[i].icon),
                  title: Text(widget.categories[i].title),
                  subtitle: Text(widget.categories[i].subtitle),
                  onTap: () => setState(() => _selected = i),
                ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey(_selected),
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder:
                    category.pageBuilder ??
                    (_) => SettingsCategoryPage(
                      title: category.title,
                      items: category.items,
                    ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
