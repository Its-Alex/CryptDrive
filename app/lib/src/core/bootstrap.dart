import 'dart:io';

import 'package:cryptdrive_native/cryptdrive_native.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/browser_api.dart' as browser;
import 'app_store.dart';
import 'perf_log.dart';
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
    required this.store,
    this.secrets,
    this.configFile,
    this.supportDir,
    this.browser,
  });

  final Rclone rclone;
  final VaultService vault;
  final AppStore store;

  /// Native only: the keystore holding the config password, and the encrypted config file.
  final SecretStore? secrets;
  final File? configFile;
  final Directory? supportDir;

  /// Browser only: the config is unlocked with a password typed in each session.
  final BrowserSession? browser;

  Future<void> shutdown() async {
    await vault.wipeOpenedFiles();
    await rclone.shutdown();
  }
}

/// The browser keeps only the encrypted rclone.conf (localStorage); its
/// password never leaves the tab, except in sessionStorage to survive reloads.
class BrowserSession {
  BrowserSession(this._rclone, this._store);

  static const configKey = 'rclone.conf';

  final Rclone _rclone;
  final AppStore _store;

  Future<bool> hasSavedConfig() async => (await _store.read(configKey))?.isNotEmpty ?? false;

  /// Throws [RcloneException] on a wrong password.
  Future<void> unlock(String password) async {
    await _rclone.unlock(password, await _store.read(configKey) ?? '');
    browser.writeSessionPassword(password);
  }

  /// Unlocks with the password remembered by this tab, if any.
  Future<bool> resume() async {
    final password = browser.readSessionPassword();
    if (password == null) return false;
    try {
      await unlock(password);
      return true;
    } on RcloneException {
      browser.writeSessionPassword(null);
      return false;
    }
  }

  void lock() => browser.writeSessionPassword(null);

  /// Deletes everything CryptDrive keeps in this browser; the vault itself is untouched.
  Future<void> forget() async {
    lock();
    await _store.delete(configKey);
    await _store.delete(recentFilesKey);
  }
}

const recentFilesKey = 'recent-files.json';

class AppDirectories {
  const AppDirectories({required this.support, required this.temporary});

  final Directory support;
  final Directory temporary;

  static Future<AppDirectories> platformDefault() async =>
      AppDirectories(support: await getApplicationSupportDirectory(), temporary: await getTemporaryDirectory());
}

Future<AppEnvironment> bootstrapBrowser({AppStore? store}) async {
  final clock = StartupClock();
  final appStore = store ?? browser.browserAppStore();
  final rclone = await Rclone.startInBrowser(
    onConfigSaved: (encryptedConf) => appStore.write(BrowserSession.configKey, encryptedConf),
  );
  clock.mark('browser engine started');
  return AppEnvironment(
    rclone: rclone,
    vault: VaultService(rclone),
    store: appStore,
    browser: BrowserSession(rclone, appStore),
  );
}

Future<AppEnvironment> bootstrap({
  required SecretStore secrets,
  AppDirectories? directories,
  String? libraryPath,
}) async {
  final clock = StartupClock();
  final dirs = directories ?? await AppDirectories.platformDefault();
  final configFile = File(p.join(dirs.support.path, 'rclone', 'rclone.conf'));
  final vault = VaultService(
    await Rclone.start(configPath: configFile.path, libraryPath: libraryPath),
    openedFilesDir: Directory(p.join(dirs.temporary.path, 'cryptdrive-opened')),
  );
  clock.mark('native library started');
  // A previous run may have been killed before it could wipe its decrypted copies.
  await vault.wipeOpenedFiles();

  String? password;
  try {
    password = await secrets.readConfigPassword();
    clock.mark('config password read from the system keystore');
    // iOS keeps Keychain items across reinstalls: a stored password with no config is reused, not an error.
    if (password == null) {
      if (await configFile.exists()) {
        throw BootstrapException(BootstrapIssue.configLocked, 'The config password is missing from the keystore.');
      }
      password = generateConfigPassword();
      await secrets.writeConfigPassword(password);
      clock.mark('new config password stored in the system keystore');
    }
  } on PlatformException catch (error) {
    throw BootstrapException(BootstrapIssue.keystoreUnavailable, error.message ?? error.code);
  }

  try {
    await vault.rclone.setConfigPassword(password);
  } on RcloneException catch (error) {
    throw BootstrapException(BootstrapIssue.configLocked, error.message);
  }
  clock.mark('config decrypted');
  return AppEnvironment(
    rclone: vault.rclone,
    vault: vault,
    store: FileAppStore(dirs.support),
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

/// Prints how long each startup phase took, to tell a slow keystore from a slow disk.
class StartupClock {
  final _watch = Stopwatch()..start();
  var _last = Duration.zero;

  void mark(String phase) {
    final now = _watch.elapsed;
    perfLog('cryptdrive startup: $phase in ${(now - _last).inMilliseconds} ms');
    _last = now;
  }
}
