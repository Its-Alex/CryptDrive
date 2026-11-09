import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/bootstrap.dart';
import '../state/providers.dart';
import 'widgets.dart';

/// Browser only: the settings (Drive token, vault passwords) are stored in
/// this browser encrypted with a password that is never stored with them.
class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key, required this.session});

  final BrowserSession session;

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool? _hasSavedConfig;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.session.hasSavedConfig().then((saved) {
      if (mounted) setState(() => _hasSavedConfig = saved);
    });
  }

  Future<void> _submit() async {
    final creating = _hasSavedConfig == false;
    if (_password.text.isEmpty) return setState(() => _error = 'Enter a password.');
    if (creating && _password.text != _confirmation.text) return setState(() => _error = 'The passwords do not match.');
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await ref.read(configUnlockedProvider.notifier).unlock(_password.text);
    } catch (error) {
      if (mounted) setState(() => _error = creating ? describeError(error) : 'Wrong password.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _forget() async {
    final proceed = await confirm(
      context,
      title: 'Forget this browser?',
      message:
          'Deletes CryptDrive\'s settings from this browser: Drive sign-in and vault passwords. '
          'Your files stay in Google Drive and can be reopened with your vault password.',
      confirmLabel: 'Forget',
    );
    if (!proceed) return;
    await widget.session.forget();
    if (mounted) setState(() => _hasSavedConfig = false);
  }

  @override
  Widget build(BuildContext context) {
    final saved = _hasSavedConfig;
    final scheme = Theme.of(context).colorScheme;
    if (saved == null) return const LoadingScreen(message: 'Starting…');
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  saved ? 'Unlock CryptDrive' : 'Protect CryptDrive in this browser',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  saved
                      ? 'Enter the password that protects CryptDrive\'s settings in this browser.'
                      : 'Choose a password for CryptDrive\'s settings in this browser (Drive sign-in, vault '
                            'passwords). It is asked for each time you open a new tab, and never leaves your device.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                TextField(
                  key: const Key('unlockPasswordField'),
                  controller: _password,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                  onSubmitted: saved ? (_) => _submit() : null,
                ),
                if (!saved) ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('unlockPasswordConfirmationField'),
                    controller: _confirmation,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Repeat password'),
                    onSubmitted: (_) => _submit(),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('unlockSubmit'),
                  onPressed: _working ? null : _submit,
                  child: Text(saved ? 'Unlock' : 'Continue'),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
                if (saved) TextButton(onPressed: _forget, child: const Text('Forgot it? Forget this browser')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
