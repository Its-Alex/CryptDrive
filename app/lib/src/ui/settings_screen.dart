import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/vault_service.dart';
import '../platform/browser_api.dart' as browser;
import '../state/providers.dart';
import 'config_transfer.dart';
import 'google_auth_form.dart';
import 'widgets.dart';

final _rcloneVersionProvider = FutureProvider.autoDispose<String>((ref) async {
  final environment = await ref.watch(environmentProvider.future);
  return (await environment.rclone.call('core/version'))['version'] as String;
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final environment = ref.watch(environmentProvider).requireValue;
    final status = ref.watch(setupStatusProvider).value;
    final rcloneVersion = ref.watch(_rcloneVersionProvider).value ?? '…';
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          _Section('Storage', [
            ListTile(
              leading: const Icon(Icons.cloud),
              title: Text(switch (status?.storageKind) {
                StorageKind.googleDrive => 'Google Drive',
                StorageKind.localFolder => 'Local folder',
                StorageKind.browserMemory => 'This tab only (lost on reload)',
                _ => status?.storageRemote ?? 'Not configured',
              }),
              subtitle: status?.clientId == null ? null : Text('OAuth client: ${status!.clientId}'),
            ),
            if (status?.storageKind == StorageKind.googleDrive)
              ListTile(
                key: const Key('changeOAuthClient'),
                leading: const Icon(Icons.key),
                title: const Text('Change OAuth client ID / secret'),
                subtitle: const Text('Signs in again: Google tokens belong to one client.'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        _ChangeClientScreen(vault: environment.vault, initialClientId: status?.clientId ?? ''),
                  ),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('How to create a Google OAuth client'),
              onTap: () => launchUrl(Uri.parse(oauthClientDocsUrl), mode: LaunchMode.externalApplication),
            ),
          ]),
          _Section('rclone configuration', [
            ListTile(
              key: const Key('exportRcloneConf'),
              leading: const Icon(Icons.upload_file),
              title: const Text('Export rclone.conf'),
              subtitle: const Text('Open this vault with the rclone CLI, RSAF or Round Sync.'),
              onTap: () => exportRcloneConfFlow(context, environment.vault),
            ),
            ListTile(
              leading: const Icon(Icons.file_open),
              title: const Text('Import rclone.conf'),
              subtitle: const Text('Replaces remotes with the same names.'),
              onTap: () async {
                final imported = await importRcloneConfFlow(context, environment.vault);
                if (imported != null) ref.invalidate(setupStatusProvider);
              },
            ),
          ]),
          if (environment.browser case final session?)
            _Section('This browser', [
              ListTile(
                key: const Key('lockBrowser'),
                leading: const Icon(Icons.lock_outline),
                title: const Text('Lock'),
                subtitle: const Text('Asks for the browser password again.'),
                onTap: () {
                  session.lock();
                  browser.reloadPage();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: const Text('Forget this browser'),
                subtitle: const Text(
                  'Deletes Drive sign-in and vault passwords from this browser. Files stay in Drive.',
                ),
                onTap: () async {
                  final proceed = await confirm(
                    context,
                    title: 'Forget this browser?',
                    message:
                        'You will need your OAuth client, a new Google sign-in and your vault password to open '
                        'the vault again here.',
                    confirmLabel: 'Forget',
                  );
                  if (!proceed) return;
                  await session.forget();
                  browser.reloadPage();
                },
              ),
            ]),
          _Section('About', [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('CryptDrive'),
              subtitle: Text('rclone $rcloneVersion · vault format: rclone crypt'),
            ),
          ]),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.tiles);

  final String title;
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: tiles),
        ),
      ],
    );
  }
}

class _ChangeClientScreen extends ConsumerWidget {
  const _ChangeClientScreen({required this.vault, required this.initialClientId});

  final VaultService vault;
  final String initialClientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('OAuth client')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          GoogleAuthForm(
            vault: vault,
            initialClientId: initialClientId,
            submitLabel: 'Save',
            onCredentials: (clientId, clientSecret, token) async {
              await vault.updateGoogleDriveClient(clientId: clientId, clientSecret: clientSecret, tokenJson: token);
              ref.invalidate(setupStatusProvider);
              if (context.mounted) {
                showMessage(context, 'OAuth client updated');
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
    );
  }
}
