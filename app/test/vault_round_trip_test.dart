import 'dart:convert';
import 'dart:io';

import 'package:cryptdrive/src/core/vault_service.dart';
import 'package:cryptdrive_native/cryptdrive_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final libraryPath = File('packages/cryptdrive_native/linux/lib/libcryptdrive.so').absolute.path;

/// The core round-trip: encrypt → upload → list → download → decrypt, against a
/// local rclone remote standing in for Google Drive, plus CRUD and config export.
void main() {
  late Directory workDir;
  late Directory storageDir;
  late Rclone rclone;
  late VaultService vault;

  setUpAll(() async {
    workDir = await Directory.systemTemp.createTemp('cryptdrive_round_trip');
    storageDir = Directory(p.join(workDir.path, 'fake-google-drive'));
    rclone = await Rclone.start(configPath: p.join(workDir.path, 'config', 'rclone.conf'), libraryPath: libraryPath);
    await rclone.setConfigPassword('app config password');
    vault = VaultService(rclone, openedFilesDir: Directory(p.join(workDir.path, 'opened')));
  });

  tearDownAll(() async {
    await rclone.shutdown();
    await workDir.delete(recursive: true);
  });

  test('onboarding creates a local storage and an rclone crypt vault', () async {
    expect((await vault.status()).hasStorage, isFalse);
    await vault.connectLocalFolder();
    final storage = await vault.status();
    expect(storage.storageKind, StorageKind.localFolder);

    await vault.configureVault(
      storageRemote: storage.storageRemote!,
      folder: p.join(storageDir.path, 'CryptDrive'),
      password: 'vault password',
      salt: 'vault salt',
    );
    final ready = await vault.status();
    expect(ready.vaultRemote, RemoteNames.vault);
    expect(ready.storageRemote, RemoteNames.localFolder);
  });

  test('upload → list → download round-trips and storage only holds ciphertext', () async {
    final photoBytes = List<int>.generate(300 * 1024, (i) => (i * 31) % 256);
    final staged = File(p.join(workDir.path, 'staging', 'holiday photo.jpg'));
    await staged.create(recursive: true);
    await staged.writeAsBytes(photoBytes);

    await vault.createFolder('Photos');
    final progress = <JobProgress>[];
    await vault.upload(staged, 'Photos', onProgress: progress.add);

    final root = await vault.list('');
    expect(root.map((e) => (e.name, e.isDir)), [('Photos', true)]);
    final photos = await vault.list('Photos');
    expect(photos.single.name, 'holiday photo.jpg');
    expect(photos.single.size, photoBytes.length);
    expect(photos.single.path, 'Photos/holiday photo.jpg');

    final storedFiles = storageDir.listSync(recursive: true);
    expect(storedFiles, isNotEmpty);
    for (final stored in storedFiles) {
      expect(p.basename(stored.path), isNot(contains('Photo')));
      expect(p.basename(stored.path), isNot(contains('holiday')));
      if (stored is File) expect(stored.readAsBytesSync(), isNot(equals(photoBytes)));
    }

    final decrypted = await vault.decryptToTemp(photos.single);
    expect(decrypted.path, startsWith(vault.openedFilesDir.path));
    expect(await decrypted.readAsBytes(), photoBytes);

    final head = await vault.readHead(photos.single, maxBytes: 1024);
    expect(head, photoBytes.sublist(0, 1024));

    await vault.wipeOpenedFiles();
    expect(vault.openedFilesDir.existsSync(), isFalse);
  });

  test('rename, move and delete files and folders', () async {
    final photo = (await vault.list('Photos')).single;
    await vault.move(photo, 'Photos/renamed.jpg');
    expect((await vault.list('Photos')).single.name, 'renamed.jpg');

    await vault.createFolder('Archive');
    final renamed = (await vault.list('Photos')).single;
    await vault.move(renamed, 'Archive/renamed.jpg');
    expect(await vault.list('Photos'), isEmpty);
    expect((await vault.list('Archive')).single.name, 'renamed.jpg');

    final archive = (await vault.list('')).firstWhere((e) => e.name == 'Archive');
    await vault.move(archive, 'Archive 2026');
    final rootNames = (await vault.list('')).map((e) => e.name).toSet();
    expect(rootNames, {'Photos', 'Archive 2026'});
    expect((await vault.list('Archive 2026')).single.name, 'renamed.jpg');

    await vault.delete((await vault.list('Archive 2026')).single);
    expect(await vault.list('Archive 2026'), isEmpty);

    await vault.upload(File(p.join(workDir.path, 'staging', 'holiday photo.jpg')), 'Archive 2026');
    await vault.delete((await vault.list('')).firstWhere((e) => e.name == 'Archive 2026'));
    expect((await vault.list('')).map((e) => e.name), ['Photos']);
  });

  test('exported rclone.conf is plain, standard and re-importable', () async {
    final conf = await vault.exportRcloneConf();
    expect(conf, contains('[vault]'));
    expect(conf, contains('type = crypt'));
    expect(conf, contains('[localstore]'));
    expect(conf, isNot(contains('vault password')), reason: 'crypt passwords stay obscured');

    final onDisk = File(p.join(workDir.path, 'config', 'rclone.conf')).readAsStringSync();
    expect(onDisk, contains('RCLONE_ENCRYPT_V0:'));
    expect(onDisk, isNot(contains('[vault]')));

    final imported = await vault.importRcloneConf(conf);
    expect(imported, containsAll(['vault', 'localstore']));
    expect((await vault.list('')).map((e) => e.name), ['Photos']);
  });

  test('the plain rclone CLI opens the vault from the exported rclone.conf, both ways', () async {
    final rcloneCli = Platform.environment['RCLONE_CLI'] ?? 'rclone';
    final staged = File(p.join(workDir.path, 'staging', 'from-app.txt'))..writeAsStringSync('written by CryptDrive');
    await vault.upload(staged, 'Photos');
    final exportedConf = File(p.join(workDir.path, 'exported-rclone.conf'))
      ..writeAsStringSync(await vault.exportRcloneConf());

    Future<String> cli(List<String> args, {String? stdin}) async {
      final process = await Process.start(rcloneCli, ['--config', exportedConf.path, ...args]);
      if (stdin != null) process.stdin.write(stdin);
      await process.stdin.close();
      final output = await process.stdout.transform(utf8.decoder).join();
      final errors = await process.stderr.transform(utf8.decoder).join();
      expect(await process.exitCode, 0, reason: 'rclone ${args.join(' ')}: $errors');
      return output;
    }

    expect(await cli(['cat', 'vault:Photos/from-app.txt']), 'written by CryptDrive');
    await cli(['rcat', 'vault:Photos/from-cli.txt'], stdin: 'written by rclone CLI');
    final fromCli = (await vault.list('Photos')).firstWhere((e) => e.name == 'from-cli.txt');
    expect(await (await vault.decryptToTemp(fromCli)).readAsString(), 'written by rclone CLI');
  }, skip: _rcloneCliMissing());

  test('Google Drive remote accepts a pasted rclone authorize token', () async {
    final token = jsonEncode({
      'access_token': 'ya29.test',
      'token_type': 'Bearer',
      'refresh_token': '1//test',
      'expiry': '2099-01-01T00:00:00Z',
    });
    await vault.connectGoogleDrive(
      clientId: 'id.apps.googleusercontent.com',
      clientSecret: 'secret',
      tokenJson: 'Paste the following into your remote machine --->\n$token\n<---End paste',
    );
    final drive = await rclone.call('config/get', {'name': RemoteNames.googleDrive});
    expect(drive['type'], 'drive');
    expect(drive['scope'], 'drive');
    expect(jsonDecode(drive['token'] as String)['refresh_token'], '1//test');
    expect(() => VaultService.normalizeToken('{"access_token":"x"}'), throwsA(isA<InvalidTokenException>()));
    await rclone.call('config/delete', {'name': RemoteNames.googleDrive});
  });
}

Object _rcloneCliMissing() {
  try {
    final result = Process.runSync(Platform.environment['RCLONE_CLI'] ?? 'rclone', ['version']);
    return result.exitCode == 0 ? false : 'rclone CLI not runnable';
  } on ProcessException {
    return 'rclone CLI not on PATH';
  }
}
