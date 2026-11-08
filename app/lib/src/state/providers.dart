import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/bootstrap.dart';
import '../core/secret_store.dart';
import '../core/vault_service.dart';

final secretStoreProvider = Provider<SecretStore>((ref) => SecureSecretStore());

/// Overridden in tests to point at temporary directories.
final appDirectoriesProvider = Provider<AppDirectories?>((ref) => null);

final environmentProvider = FutureProvider<AppEnvironment>((ref) {
  return bootstrap(secrets: ref.watch(secretStoreProvider), directories: ref.watch(appDirectoriesProvider));
});

final setupStatusProvider = FutureProvider<SetupStatus>((ref) async {
  final environment = await ref.watch(environmentProvider.future);
  return environment.vault.status();
});

final folderProvider = FutureProvider.autoDispose.family<List<VaultEntry>, String>((ref, directory) async {
  final environment = await ref.watch(environmentProvider.future);
  return environment.vault.list(directory);
});
