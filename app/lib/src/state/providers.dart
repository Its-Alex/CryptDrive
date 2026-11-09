import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/bootstrap.dart';
import '../core/secret_store.dart';
import '../core/vault_service.dart';

final secretStoreProvider = Provider<SecretStore>((ref) => SecureSecretStore());

/// Overridden in tests to point at temporary directories.
final appDirectoriesProvider = Provider<AppDirectories?>((ref) => null);

final environmentProvider = FutureProvider<AppEnvironment>((ref) {
  if (kIsWeb) return bootstrapBrowser();
  return bootstrap(secrets: ref.watch(secretStoreProvider), directories: ref.watch(appDirectoriesProvider));
});

/// Whether the config can be read: always on native apps; in a browser, once
/// the user typed the password (or the tab still remembers it).
class ConfigUnlocked extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final session = (await ref.watch(environmentProvider.future)).browser;
    return session == null || await session.resume();
  }

  /// Throws on a wrong password.
  Future<void> unlock(String password) async {
    final session = (await ref.read(environmentProvider.future)).browser!;
    await session.unlock(password);
    state = const AsyncData(true);
  }
}

final configUnlockedProvider = AsyncNotifierProvider<ConfigUnlocked, bool>(ConfigUnlocked.new);

final setupStatusProvider = FutureProvider<SetupStatus>((ref) async {
  final environment = await ref.watch(environmentProvider.future);
  await ref.watch(configUnlockedProvider.future);
  return environment.vault.status();
});

final searchProvider = FutureProvider.autoDispose.family<List<VaultEntry>, String>((ref, query) async {
  final environment = await ref.watch(environmentProvider.future);
  return environment.vault.search(query);
});

final folderProvider = FutureProvider.autoDispose.family<List<VaultEntry>, String>((ref, directory) async {
  final environment = await ref.watch(environmentProvider.future);
  return environment.vault.list(directory);
});
