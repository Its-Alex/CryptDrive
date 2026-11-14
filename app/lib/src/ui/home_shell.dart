import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'files_tab.dart';
import 'recent_tab.dart';
import 'settings_screen.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const _destinations = [
    (icon: Icons.folder_outlined, selected: Icons.folder, label: 'Files', key: Key('openFiles')),
    (icon: Icons.history, selected: Icons.history, label: 'Recent', key: Key('openRecent')),
    (icon: Icons.settings_outlined, selected: Icons.settings, label: 'Settings', key: Key('openSettings')),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(homeTabProvider);
    void select(int index) => ref.read(homeTabProvider.notifier).select(index);
    final body = IndexedStack(
      index: tab,
      children: [
        FilesTab(active: tab == 0),
        const RecentTab(),
        const SettingsScreen(),
      ],
    );
    final wide = MediaQuery.sizeOf(context).width >= 840;
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: tab,
              onDestinationSelected: select,
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
        selectedIndex: tab,
        onDestinationSelected: select,
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
