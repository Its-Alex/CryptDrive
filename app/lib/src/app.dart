import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/bootstrap.dart';
import 'state/providers.dart';
import 'ui/home_shell.dart';
import 'ui/onboarding_screen.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

/// Riverpod 3 retries failed providers by default; bootstrap failures need the user instead.
Duration? noRetry(int retryCount, Object error) => null;

class CryptDriveApp extends StatelessWidget {
  const CryptDriveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CryptDrive',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerStatefulWidget {
  const _Root();

  @override
  ConsumerState<_Root> createState() => _RootState();
}

class _RootState extends ConsumerState<_Root> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _shutdown();
        return AppExitResponse.exit;
      },
      onDetach: _shutdown,
    );
  }

  Future<void> _shutdown() async {
    final environment = ref.read(environmentProvider).value;
    await environment?.shutdown();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final environment = ref.watch(environmentProvider);
    final screen = environment.when(
      loading: () => const LoadingScreen(message: 'Starting…'),
      error: (error, _) => _BootstrapErrorScreen(error: error),
      data: (_) {
        final status = ref.watch(setupStatusProvider);
        return status.when(
          loading: () => const LoadingScreen(message: 'Reading configuration…'),
          error: (error, _) => ErrorScreen(error: error, onRetry: () => ref.invalidate(setupStatusProvider)),
          data: (status) => status.hasStorage && status.hasVault ? const HomeShell() : OnboardingScreen(status: status),
        );
      },
    );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: KeyedSubtree(key: ValueKey(screen.runtimeType), child: screen),
    );
  }
}

class _BootstrapErrorScreen extends ConsumerWidget {
  const _BootstrapErrorScreen({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final issue = error is BootstrapException ? (error as BootstrapException).issue : null;
    final (title, explanation) = switch (issue) {
      BootstrapIssue.keystoreUnavailable => (
        'No system keystore',
        'CryptDrive keeps its config password in the system keystore. On Linux this needs a running '
            'Secret Service (GNOME Keyring, KWallet, KeePassXC…). Start one, then retry.',
      ),
      BootstrapIssue.configLocked => (
        'Configuration locked',
        'The saved configuration can no longer be decrypted (its password is missing from the keystore, '
            'e.g. after a restore). Reset to set up again: your vault itself is untouched and can be '
            'reopened with its vault password.',
      ),
      null => ('CryptDrive could not start', ''),
    };
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                if (explanation.isNotEmpty) Text(explanation),
                const SizedBox(height: 12),
                SelectableText('$error', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(onPressed: () => ref.invalidate(environmentProvider), child: const Text('Retry')),
                    if (issue == BootstrapIssue.configLocked)
                      OutlinedButton(
                        onPressed: () async {
                          await resetLockedConfig(
                            secrets: ref.read(secretStoreProvider),
                            directories: ref.read(appDirectoriesProvider),
                          );
                          ref.invalidate(environmentProvider);
                        },
                        child: const Text('Reset configuration'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
