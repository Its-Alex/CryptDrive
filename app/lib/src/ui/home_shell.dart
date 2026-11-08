import 'package:flutter/material.dart';

import 'files_tab.dart';
import 'recent_tab.dart';
import 'settings_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static const _destinations = [
    (icon: Icons.folder_outlined, selected: Icons.folder, label: 'Files', key: Key('openFiles')),
    (icon: Icons.history, selected: Icons.history, label: 'Recent', key: Key('openRecent')),
    (icon: Icons.settings_outlined, selected: Icons.settings, label: 'Settings', key: Key('openSettings')),
  ];

  void _select(int index) => setState(() => _tab = index);

  @override
  Widget build(BuildContext context) {
    final body = IndexedStack(index: _tab, children: const [FilesTab(), RecentTab(), SettingsScreen()]);
    final wide = MediaQuery.sizeOf(context).width >= 840;
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: _select,
              labelType: NavigationRailLabelType.all,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Icon(Icons.lock_rounded, color: Theme.of(context).colorScheme.primary),
              ),
              destinations: [
                for (final destination in _destinations)
                  NavigationRailDestination(
                    icon: Icon(destination.icon, key: destination.key),
                    selectedIcon: Icon(destination.selected),
                    label: Text(destination.label),
                  ),
              ],
            ),
            Expanded(child: body),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _select,
        destinations: [
          for (final destination in _destinations)
            NavigationDestination(
              key: destination.key,
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selected),
              label: destination.label,
            ),
        ],
      ),
    );
  }
}
