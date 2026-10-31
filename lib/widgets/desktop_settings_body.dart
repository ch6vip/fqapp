import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../pages/settings_category_page.dart';
import 'home/home_design.dart';
import 'settings/settings_widgets.dart';

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
    final palette = HomePalette.of(context);
    final category = widget.categories[_selected];
    return Row(
      children: [
        SizedBox(
          width: 248,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (var i = 0; i < widget.categories.length; i++)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: _selected == i ? palette.soft : null,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SettingsRow(
                    icon: widget.categories[i].icon,
                    title: widget.categories[i].title,
                    subtitle: widget.categories[i].subtitle,
                    showChevron: false,
                    trailing: _selected == i
                        ? Icon(
                            LucideIcons.check,
                            size: 16,
                            color: palette.accentText,
                          )
                        : null,
                    onTap: () => setState(() => _selected = i),
                  ),
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
                      itemsBuilder: category.itemsBuilder,
                    ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
