import 'dart:io';

import 'package:cryptdrive_native/cryptdrive_native.dart';
import 'package:flutter_test/flutter_test.dart';

final libraryPath = File('linux/lib/libcryptdrive.so').absolute.path;

void main() {
  late Directory workDir;
  late Rclone rclone;

  setUpAll(() async {
    workDir = await Directory.systemTemp.createTemp('cryptdrive_native_test');
    rclone = await Rclone.start(configPath: '${workDir.path}/rclone.conf', libraryPath: libraryPath);
    await rclone.setConfigPassword('test config password');
  });

  tearDownAll(() async {
    await rclone.shutdown();
    await workDir.delete(recursive: true);
  });

  test('exports the whole C API', () {
    final bindings = CryptDriveBindings(openCryptDriveLibrary(libraryPath));
    expect(bindings.rpc('rc/noop', '{"echo":"é✓"}').output, contains('é✓'));
  });

  test('rc call returns decoded JSON', () async {
    expect(await rclone.call('rc/noop', {'answer': 42}), {'answer': 42});
  });

  test('rc errors surface as RcloneException with status', () async {
    await expectLater(
      rclone.call('no/such/method'),
      throwsA(isA<RcloneException>().having((e) => e.status, 'status', 404)),
    );
    await expectLater(
      rclone.call('operations/list', {'fs': 'missing-remote:', 'remote': ''}),
      throwsA(isA<RcloneException>().having((e) => e.message, 'message', contains('missing-remote'))),
    );
  });

  test('async jobs report output and failures', () async {
    final source = await Directory('${workDir.path}/src').create();
    await File('${source.path}/a.txt').writeAsString('hello');
    final progress = <JobProgress>[];
    await rclone.runJob('operations/copyfile', {
      'srcFs': source.path,
      'srcRemote': 'a.txt',
      'dstFs': '${workDir.path}/dst',
      'dstRemote': 'a.txt',
    }, onProgress: progress.add);
    expect(File('${workDir.path}/dst/a.txt').readAsStringSync(), 'hello');
    await expectLater(
      rclone.runJob('operations/copyfile', {
        'srcFs': source.path,
        'srcRemote': 'missing.txt',
        'dstFs': '${workDir.path}/dst',
        'dstRemote': 'missing.txt',
      }),
      throwsA(isA<RcloneException>()),
    );
  });

  test('wrong config password is rejected once the encrypted config exists', () async {
    await rclone.call('config/create', {
      'name': 'local',
      'type': 'local',
      'parameters': <String, dynamic>{},
      'opt': {'nonInteractive': true},
    });
    expect(File('${workDir.path}/rclone.conf').readAsStringSync(), contains('RCLONE_ENCRYPT_V0:'));
    await expectLater(rclone.setConfigPassword('wrong'), throwsA(isA<RcloneException>()));
    await rclone.setConfigPassword('test config password');
    expect((await rclone.call('config/listremotes'))['remotes'], contains('local'));
  });
}
