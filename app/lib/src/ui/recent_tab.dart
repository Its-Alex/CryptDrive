import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/vault_service.dart';
import '../state/providers.dart';
import '../state/recent_files.dart';
import '../state/transfers.dart';
import 'entry_widgets.dart';
import 'file_actions.dart';
import 'widgets.dart';

class RecentTab extends ConsumerWidget {
  const RecentTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentFilesProvider);
    final transfers = ref.watch(transfersProvider);
    final vault = ref.watch(environmentProvider).requireValue.vault;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Recent')),
      body: recent.when(
        loading: () => const SkeletonList(),
        error: (error, _) => ErrorView(error: error, onRetry: () => ref.invalidate(recentFilesProvider)),
        data: (items) {
          if (items.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 48, color: scheme.outline),
                  const SizedBox(height: 12),
                  const Text('Files you open or upload show up here.'),
                ],
              ),
            );
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final folder = parentVaultPath(item.entry.path);
              final verb = item.action == RecentAction.opened ? 'Opened' : 'Uploaded';
              return EntryRow(
                key: Key('recent:${item.entry.path}'),
                entry: item.entry,
                vault: vault,
                transfer: transfers[item.entry.path],
                subtitleOverride: '$verb ${formatDate(item.at)} · in ${folder.isEmpty ? 'Vault' : folder}',
                onTap: () => FileActions(context, ref).run(item.entry, EntryAction.open),
                onMenu: () async {
                  final action = await showEntryActions(context, item.entry, vault);
                  if (action != null && context.mounted) await FileActions(context, ref).run(item.entry, action);
                },
              );
            },
          );
        },
      ),
    );
  }
}
