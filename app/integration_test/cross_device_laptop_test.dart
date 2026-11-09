import 'dart:io';

import 'package:cryptdrive/src/app.dart';
import 'package:cryptdrive/src/core/bootstrap.dart';
import 'package:cryptdrive/src/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';
import 'cross_device_phone_test.dart' show photoBytes;

/// Laptop half of the cross-device check: imports the phone's exported
/// rclone.conf and opens the photo the phone uploaded.
const crossDeviceDir = String.fromEnvironment('CROSS_DEVICE_DIR');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('laptop: import the phone vault and open its photo', (tester) async {
    expect(crossDeviceDir, isNotEmpty, reason: 'pass --dart-define=CROSS_DEVICE_DIR=…');
    final runDir = await Directory.systemTemp.createTemp('cryptdrive-laptop');
    final container = ProviderContainer(
      retry: noRetry,
      overrides: [
        appDirectoriesProvider.overrideWithValue(
          AppDirectories(
            support: Directory(p.join(runDir.path, 'support')),
            temporary: Directory(p.join(runDir.path, 'tmp')),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const CryptDriveApp()));
    await pumpUntilFound(tester, find.text('Set up CryptDrive'));
    final environment = container.read(environmentProvider).requireValue;

    final conf = await File(p.join(crossDeviceDir, 'laptop-rclone.conf')).readAsString();
    expect(await environment.vault.importRcloneConf(conf), containsAll(['vault', 'localstore']));
    container.invalidate(setupStatusProvider);
    await pumpUntilFound(tester, find.byKey(const Key('entry:IMG_0001.png')));

    await chooseMenuAction(tester, 'IMG_0001.png', 'Preview');
    await pumpUntilFound(tester, find.byType(Image));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    final photo = (await environment.vault.list('')).single;
    expect(await (await environment.vault.decryptToTemp(photo)).readAsBytes(), photoBytes);

    await environment.shutdown();
    await environment.secrets!.deleteConfigPassword();
    await runDir.delete(recursive: true);
  });
}
