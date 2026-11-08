import 'dart:io';

import 'package:cryptdrive_native/cryptdrive_native.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'secret_store.dart';
import 'vault_service.dart';

enum BootstrapIssue {
  /// No OS keystore (e.g. Linux without a running Secret Service).
  keystoreUnavailable,

  /// The config exists but its password is missing from the keystore or wrong.
  configLocked,
}

class BootstrapException implements Exception {
  BootstrapException(this.issue, this.detail);

  final BootstrapIssue issue;
  final String detail;

  @override
  String toString() => '$issue: $detail';
}

class AppEnvironment {
  AppEnvironment({
    required this.rclone,
    required this.vault,
    required this.secrets,
    required this.configFile,
    required this.supportDir,
  });

  final Rclone rclone;
  final VaultService vault;
  final SecretStore secrets;
  final File configFile;
  final Directory supportDir;

  Future<void> shutdown() async {
    await vault.wipeOpenedFiles();
    await rclone.shutdown();
  }
}

class AppDirectories {
  const AppDirectories({required this.support, required this.temporary});

  final Directory support;
  final Directory temporary;

  static Future<AppDirectories> platformDefault() async =>
      AppDirectories(support: await getApplicationSupportDirectory(), temporary: await getTemporaryDirectory());
}

Future<AppEnvironment> bootstrap({
  required SecretStore secrets,
  AppDirectories? directories,
  String? libraryPath,
}) async {
  final dirs = directories ?? await AppDirectories.platformDefault();
  final configFile = File(p.join(dirs.support.path, 'rclone', 'rclone.conf'));
  final vault = VaultService(
    await Rclone.start(configPath: configFile.path, libraryPath: libraryPath),
    openedFilesDir: Directory(p.join(dirs.temporary.path, 'cryptdrive-opened')),
  );
  // A previous run may have been killed before it could wipe its decrypted copies.
  await vault.wipeOpenedFiles();

  String? password;
  try {
    password = await secrets.readConfigPassword();
    // iOS keeps Keychain items across reinstalls: a stored password with no config is reused, not an error.
    if (password == null) {
      if (await configFile.exists()) {
        throw BootstrapException(BootstrapIssue.configLocked, 'The config password is missing from the keystore.');
      }
      password = generateConfigPassword();
      await secrets.writeConfigPassword(password);
    }
  } on PlatformException catch (error) {
    throw BootstrapException(BootstrapIssue.keystoreUnavailable, error.message ?? error.code);
  }

  try {
    await vault.rclone.setConfigPassword(password);
  } on RcloneException catch (error) {
    throw BootstrapException(BootstrapIssue.configLocked, error.message);
  }
  return AppEnvironment(
    rclone: vault.rclone,
    vault: vault,
    secrets: secrets,
    configFile: configFile,
    supportDir: dirs.support,
  );
}

/// Forgets the unreadable config and its password; the user sets up again.
Future<void> resetLockedConfig({required SecretStore secrets, AppDirectories? directories}) async {
  final dirs = directories ?? await AppDirectories.platformDefault();
  final configFile = File(p.join(dirs.support.path, 'rclone', 'rclone.conf'));
  if (await configFile.exists()) await configFile.delete();
  try {
    await secrets.deleteConfigPassword();
  } on PlatformException {
    // Keystore unavailable: nothing stored to forget.
  }
}
