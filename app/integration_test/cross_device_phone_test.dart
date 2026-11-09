import 'dart:io';
import 'dart:typed_data';

import 'package:cryptdrive/src/app.dart';
import 'package:cryptdrive/src/core/bootstrap.dart';
import 'package:cryptdrive/src/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'helpers.dart';

/// Phone half of the cross-device check (tools/cross-device-check.sh): creates a
/// vault in a local folder standing in for Drive, uploads a photo, exports rclone.conf.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone: create vault, upload a photo, export rclone.conf', (tester) async {
    final crossDevice = Directory(p.join((await getApplicationSupportDirectory()).path, 'cross-device'));
    if (await crossDevice.exists()) await crossDevice.delete(recursive: true);
    final container = ProviderContainer(
      retry: noRetry,
      overrides: [
        appDirectoriesProvider.overrideWithValue(
          AppDirectories(
            support: Directory(p.join(crossDevice.path, 'support')),
            temporary: Directory(p.join(crossDevice.path, 'tmp')),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const CryptDriveApp()));
    await pumpUntilFound(tester, find.text('Set up CryptDrive'));
    final environment = container.read(environmentProvider).requireValue;

    await tester.tap(find.byKey(const Key('chooseLocalFolder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('useLocalFolder')));
    await pumpUntilFound(tester, find.byKey(const Key('vaultPasswordField')));
    await tester.enterText(find.byKey(const Key('vaultFolderField')), p.join(crossDevice.path, 'drive', 'CryptDrive'));
    await tester.enterText(find.byKey(const Key('vaultPasswordField')), 'cross device password');
    await tester.enterText(find.byKey(const Key('vaultPasswordConfirmationField')), 'cross device password');
    await tapVisible(tester, find.byKey(const Key('vaultSubmit')));
    await pumpUntilFound(tester, find.text('This folder is empty.'));

    final photo = File(p.join(crossDevice.path, 'camera', 'IMG_0001.png'));
    await photo.create(recursive: true);
    await photo.writeAsBytes(photoBytes);
    await environment.vault.upload(photo, '');
    await tester.tap(find.byTooltip('Refresh'));
    await pumpUntilFound(tester, find.byKey(const Key('entry:IMG_0001.png')));

    await File(p.join(crossDevice.path, 'exported-rclone.conf'))
        .writeAsString(await environment.vault.exportRcloneConf());
    await environment.shutdown();
    await environment.secrets!.deleteConfigPassword();
  });
}

/// A 1×1 red PNG: small enough for operations/getfile previews.
final photoBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
  0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
  0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);
