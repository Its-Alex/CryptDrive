import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/vault_service.dart';
import 'widgets.dart';

const oauthClientDocsUrl = 'https://github.com/Its-Alex/CryptDrive/blob/main/docs/google-oauth-client.md';

/// Client ID/secret entry plus the two ways to get a token: in-app sign-in, or
/// pasting the output of `rclone authorize` run elsewhere.
class GoogleAuthForm extends StatefulWidget {
  const GoogleAuthForm({
    super.key,
    required this.vault,
    required this.onCredentials,
    this.initialClientId = '',
    this.submitLabel = 'Connect',
  });

  final VaultService vault;
  final Future<void> Function(String clientId, String clientSecret, String tokenJson) onCredentials;
  final String initialClientId;
  final String submitLabel;

  @override
  State<GoogleAuthForm> createState() => _GoogleAuthFormState();
}

class _GoogleAuthFormState extends State<GoogleAuthForm> {
  late final _clientId = TextEditingController(text: widget.initialClientId);
  final _clientSecret = TextEditingController();
  final _pastedToken = TextEditingController();
  bool _authorizing = false;
  bool _working = false;
  String? _error;

  String get _authorizeCommand => 'rclone authorize "drive" "${_clientId.text.trim()}" "${_clientSecret.text.trim()}"';

  bool _checkClient() {
    if (_clientId.text.trim().isEmpty) {
      setState(() => _error = 'Enter your OAuth client ID first.');
      return false;
    }
    return true;
  }

  Future<void> _signIn() async {
    if (!_checkClient()) return;
    setState(() {
      _authorizing = true;
      _error = null;
    });
    try {
      final token = await widget.vault.authorizeGoogleDrive(
        clientId: _clientId.text.trim(),
        clientSecret: _clientSecret.text.trim(),
        openUrl: (url) async {
          if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
            if (mounted) setState(() => _error = 'Open this address in a browser: $url');
          }
        },
      );
      await _submit(token);
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _authorizing = false);
    }
  }

  Future<void> _submit(String token) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onCredentials(_clientId.text.trim(), _clientSecret.text.trim(), token);
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Google requires your own OAuth client (type "Desktop app", scope "drive"). '
          'It takes about five minutes in the Google Cloud console.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.help_outline),
            label: const Text('How to create an OAuth client'),
            onPressed: () => launchUrl(Uri.parse(oauthClientDocsUrl), mode: LaunchMode.externalApplication),
          ),
        ),
        TextField(
          key: const Key('clientIdField'),
          controller: _clientId,
          decoration: const InputDecoration(labelText: 'Client ID', hintText: '…apps.googleusercontent.com'),
        ),
        TextField(
          key: const Key('clientSecretField'),
          controller: _clientSecret,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Client secret'),
        ),
        const SizedBox(height: 16),
        if (_authorizing)
          Row(
            children: [
              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              const Expanded(child: Text('Waiting for Google sign-in in your browser…')),
              TextButton(onPressed: widget.vault.cancelAuthorization, child: const Text('Cancel')),
            ],
          )
        else
          FilledButton.icon(
            key: const Key('signInWithGoogle'),
            icon: const Icon(Icons.login),
            label: const Text('Sign in with Google'),
            onPressed: _working ? null : _signIn,
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Or paste a token from another computer'),
          children: [
            Text('Run this with the rclone CLI, sign in, then paste everything it prints:', style: textTheme.bodySmall),
            ListenableBuilder(
              listenable: Listenable.merge([_clientId, _clientSecret]),
              builder: (context, _) => Row(
                children: [
                  Expanded(
                    child: SelectableText(_authorizeCommand, style: const TextStyle(fontFamily: 'monospace')),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy),
                    onPressed: () => Clipboard.setData(ClipboardData(text: _authorizeCommand)),
                  ),
                ],
              ),
            ),
            TextField(
              key: const Key('pastedTokenField'),
              controller: _pastedToken,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(labelText: 'Token JSON', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(
                key: const Key('usePastedToken'),
                onPressed: _working || _authorizing
                    ? null
                    : () {
                        if (_checkClient()) _submit(_pastedToken.text);
                      },
                child: Text(widget.submitLabel),
              ),
            ),
          ],
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
