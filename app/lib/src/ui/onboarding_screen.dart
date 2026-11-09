import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/vault_service.dart';
import '../state/providers.dart';
import 'config_transfer.dart';
import 'google_auth_form.dart';
import 'widgets.dart';

class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key, required this.status});

  final SetupStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final environment = ref.watch(environmentProvider).requireValue;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
              children: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(color: scheme.primaryContainer, shape: BoxShape.circle),
                    child: Icon(Icons.lock_rounded, size: 36, color: scheme.onPrimaryContainer),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Set up CryptDrive',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  'Your files are encrypted on this device before they reach the cloud.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                _StepCard(
                  number: 1,
                  title: 'Connect your storage',
                  done: status.hasStorage,
                  child: !status.hasStorage
                      ? _StorageStep(vault: environment.vault, onDone: () => ref.invalidate(setupStatusProvider))
                      : Text(switch (status.storageKind) {
                          StorageKind.googleDrive => 'Google Drive connected (client ${status.clientId ?? ''}).',
                          StorageKind.localFolder => 'Using a local folder instead of Google Drive.',
                          StorageKind.browserMemory => 'Using this tab\'s memory instead of Google Drive.',
                          _ => 'Storage "${status.storageRemote}" configured.',
                        }),
                ),
                const SizedBox(height: 16),
                _StepCard(
                  number: 2,
                  title: 'Create or open your vault',
                  done: status.hasVault,
                  child: status.hasStorage
                      ? _VaultStep(
                          vault: environment.vault,
                          status: status,
                          localFolderBase: p.join(environment.supportDir?.path ?? '', 'local-storage'),
                          onDone: () => ref.invalidate(setupStatusProvider),
                        )
                      : Text('Connect your storage first.', style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
                const SizedBox(height: 16),
                Center(
                  child: TextButton.icon(
                    key: const Key('importRcloneConf'),
                    icon: const Icon(Icons.file_open),
                    label: const Text('Already use rclone? Import an rclone.conf'),
                    onPressed: () async {
                      final imported = await importRcloneConfFlow(context, environment.vault);
                      if (imported != null) ref.invalidate(setupStatusProvider);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.number, required this.title, required this.done, required this.child});

  final int number;
  final String title;
  final bool done;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StepHeader(number: number, title: title, done: done),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.number, required this.title, required this.done});

  final int number;
  final String title;
  final bool done;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          CircleAvatar(radius: 14, child: done ? const Icon(Icons.check, size: 16) : Text('$number')),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
        ],
      ),
    );
  }
}

enum _StorageChoice { googleDrive, localFolder }

class _StorageStep extends StatefulWidget {
  const _StorageStep({required this.vault, required this.onDone});

  final VaultService vault;
  final VoidCallback onDone;

  @override
  State<_StorageStep> createState() => _StorageStepState();
}

class _StorageStepState extends State<_StorageStep> {
  _StorageChoice _choice = _StorageChoice.googleDrive;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_StorageChoice>(
          segments: [
            const ButtonSegment(
              value: _StorageChoice.googleDrive,
              icon: Icon(Icons.cloud),
              label: Text('Google Drive'),
            ),
            ButtonSegment(
              value: _StorageChoice.localFolder,
              icon: Icon(kIsWeb ? Icons.tab : Icons.folder),
              label: Text(kIsWeb ? 'This tab only' : 'Local folder', key: const Key('chooseLocalFolder')),
            ),
          ],
          selected: {_choice},
          onSelectionChanged: (selection) => setState(() => _choice = selection.single),
        ),
        const SizedBox(height: 16),
        if (_choice == _StorageChoice.googleDrive)
          GoogleAuthForm(
            vault: widget.vault,
            onCredentials: (clientId, clientSecret, token) async {
              await widget.vault.connectGoogleDrive(clientId: clientId, clientSecret: clientSecret, tokenJson: token);
              widget.onDone();
            },
          )
        else ...[
          const Text(
            kIsWeb
                ? 'Keeps the encrypted vault in this tab\'s memory instead of Google Drive: everything is gone '
                      'when you reload, and empty folders are not kept. Meant for trying CryptDrive out without a Google account.'
                : 'Stores the encrypted vault in a folder on this device instead of Google Drive. '
                      'Meant for trying CryptDrive out and for testing without a Google account.',
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('useLocalFolder'),
            onPressed: () async {
              try {
                await (kIsWeb ? widget.vault.connectBrowserMemory() : widget.vault.connectLocalFolder());
                widget.onDone();
              } catch (error) {
                if (context.mounted) showMessage(context, describeError(error));
              }
            },
            child: Text(kIsWeb ? 'Try it in this tab' : 'Use a local folder'),
          ),
        ],
      ],
    );
  }
}

enum _VaultChoice { create, open }

class _VaultStep extends StatefulWidget {
  const _VaultStep({required this.vault, required this.status, required this.localFolderBase, required this.onDone});

  final VaultService vault;
  final SetupStatus status;
  final String localFolderBase;
  final VoidCallback onDone;

  @override
  State<_VaultStep> createState() => _VaultStepState();
}

class _VaultStepState extends State<_VaultStep> {
  _VaultChoice _choice = _VaultChoice.create;
  late final _folder = TextEditingController(
    text: widget.status.storageKind == StorageKind.localFolder
        ? p.join(widget.localFolderBase, 'CryptDrive')
        : 'CryptDrive',
  );
  final _password = TextEditingController();
  final _passwordConfirmation = TextEditingController();
  final _salt = TextEditingController();
  bool _working = false;
  String? _error;

  Future<void> _submit() async {
    final creating = _choice == _VaultChoice.create;
    if (_password.text.isEmpty) return setState(() => _error = 'Choose a vault password.');
    if (creating && _password.text != _passwordConfirmation.text) {
      return setState(() => _error = 'The passwords do not match.');
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.vault.configureVault(
        storageRemote: widget.status.storageRemote!,
        folder: _folder.text,
        password: _password.text,
        salt: _salt.text,
        mustExist: !creating,
      );
      widget.onDone();
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final creating = _choice == _VaultChoice.create;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_VaultChoice>(
          segments: const [
            ButtonSegment(value: _VaultChoice.create, icon: Icon(Icons.add), label: Text('New vault')),
            ButtonSegment(value: _VaultChoice.open, icon: Icon(Icons.lock_open), label: Text('Existing vault')),
          ],
          selected: {_choice},
          onSelectionChanged: (selection) => setState(() => _choice = selection.single),
        ),
        const SizedBox(height: 8),
        Text(
          creating
              ? 'A vault is a folder whose file names and contents are encrypted with rclone crypt. '
                    'There is no password recovery: if you lose the password, the files are lost.'
              : 'Open a folder encrypted with rclone crypt (this app, rclone, RSAF, Round Sync…) '
                    'using the same password and salt.',
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('vaultFolderField'),
          controller: _folder,
          decoration: InputDecoration(
            labelText: switch (widget.status.storageKind) {
              StorageKind.localFolder => 'Folder path',
              StorageKind.googleDrive => 'Folder in Google Drive',
              _ => 'Folder',
            },
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('vaultPasswordField'),
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Vault password'),
        ),
        if (creating) const SizedBox(height: 12),
        if (creating)
          TextField(
            key: const Key('vaultPasswordConfirmationField'),
            controller: _passwordConfirmation,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Repeat vault password'),
          ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('vaultSaltField'),
          controller: _salt,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Salt (optional second password, "password2" in rclone)'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('vaultSubmit'),
          onPressed: _working ? null : _submit,
          child: Text(creating ? 'Create vault' : 'Open vault'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
      ],
    );
  }
}
