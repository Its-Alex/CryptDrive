import 'dart:convert';

import 'package:cryptdrive/src/app.dart';
import 'package:cryptdrive/src/core/bootstrap.dart';
import 'package:cryptdrive/src/state/providers.dart';
import 'package:cryptdrive_native/cryptdrive_native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers.dart';

/// The zero-knowledge web app in a real browser: rclone crypt runs as
/// WebAssembly in a worker, with the tab's memory standing in for Google Drive.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('unlock, create a vault, upload, browse, CRUD and preview in the browser', (tester) async {
    final container = ProviderContainer(retry: noRetry);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const CryptDriveApp()));
    await pumpUntilFound(tester, find.text('Protect CryptDrive in this browser'));
    final environment = container.read(environmentProvider).requireValue;
    await environment.browser!.forget();

    await setText(tester, find.byKey(const Key('unlockPasswordField')), 'browser password');
    await setText(tester, find.byKey(const Key('unlockPasswordConfirmationField')), 'browser password');
    await tapVisible(tester, find.byKey(const Key('unlockSubmit')));
    await pumpUntilFound(tester, find.text('Set up CryptDrive'));

    await tapVisible(tester, find.byKey(const Key('chooseLocalFolder')));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const Key('useLocalFolder')));
    await pumpUntilFound(tester, find.byKey(const Key('vaultPasswordField')));
    await setText(tester, find.byKey(const Key('vaultPasswordField')), 'vault password');
    await setText(tester, find.byKey(const Key('vaultPasswordConfirmationField')), 'vault password');
    await tapVisible(tester, find.byKey(const Key('vaultSubmit')));
    await pumpUntilFound(tester, find.text('This folder is empty.'));

    final savedConf = await environment.store.read(BrowserSession.configKey);
    expect(savedConf, contains('RCLONE_ENCRYPT_V0:'));
    expect(savedConf, isNot(contains('[vault]')));

    // Upload, as the browser file picker does with the picked file's bytes.
    final notes = Uint8List.fromList(utf8.encode('meet at the old oak tree'));
    await environment.vault.uploadBytes(notes, '', 'notes.txt');
    final photo = Uint8List.fromList(List.generate(3 * 1024 * 1024 + 17, (i) => i % 253));
    await environment.vault.uploadBytes(photo, '', 'big.bin');
    await tester.tap(find.byTooltip('Refresh'));
    await pumpUntilFound(tester, find.byKey(const Key('entry:notes.txt')));

    final stored = await environment.rclone.call('operations/list', {
      'fs': 'memorystore:CryptDrive',
      'remote': '',
      'opt': {'recurse': true},
    });
    for (final item in (stored['list'] as List).cast<Map<String, dynamic>>()) {
      expect(item['Name'], isNot(contains('notes')));
      if (item['IsDir'] != true) {
        final raw = await environment.rclone.readFile('memorystore:CryptDrive', item['Path'] as String);
        expect(String.fromCharCodes(raw).contains('oak tree'), isFalse);
      }
    }

    final big = (await environment.vault.list('')).firstWhere((entry) => entry.name == 'big.bin');
    final parts = await environment.vault.downloadBytes(big, chunkBytes: 1024 * 1024);
    expect(parts.length, 4);
    expect(parts.expand((part) => part).toList(), photo);

    await chooseMenuAction(tester, 'notes.txt', 'Preview');
    await pumpUntilFound(tester, find.textContaining('meet at the old oak tree'));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // The memory backend keeps no empty folders: a folder exists once it holds a file.
    await environment.vault.uploadBytes(Uint8List.fromList(utf8.encode('cover')), 'Photos', 'cover.txt');
    await tester.tap(find.byTooltip('Refresh'));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos')));

    await chooseMenuAction(tester, 'notes.txt', 'Rename');
    await setText(tester, find.byKey(const Key('askTextField')), 'plans.txt');
    await tester.tap(find.byKey(const Key('askTextConfirm')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:plans.txt')));

    await chooseMenuAction(tester, 'plans.txt', 'Move');
    await setText(tester, find.byKey(const Key('askTextField')), 'Photos');
    await tester.tap(find.byKey(const Key('askTextConfirm')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:plans.txt')));

    await chooseMenuAction(tester, 'big.bin', 'Delete');
    await tester.tap(find.byKey(const Key('confirmButton')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:big.bin')));

    // Multiple selection, with the keyboard shortcuts of a desktop browser.
    for (final name in ['x.txt', 'y.txt', 'z.txt']) {
      await environment.vault.uploadBytes(Uint8List.fromList(utf8.encode(name)), '', name);
    }
    await tester.tap(find.byTooltip('Refresh'));
    await pumpUntilFound(tester, find.byKey(const Key('entry:z.txt')));
    await tester.longPress(find.byKey(const Key('entry:x.txt')));
    await pumpUntilFound(tester, find.text('1 selected'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape, physicalKey: PhysicalKeyboardKey.escape);
    await pumpUntilGone(tester, find.byKey(const Key('selectionCount')));
    // Shift-click starts a range from the clicked row, even with nothing selected yet,
    // and a later Shift-click shrinks it instead of piling up.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
    await tester.tap(find.byKey(const Key('entry:x.txt')));
    await pumpUntilFound(tester, find.text('1 selected'));
    await tester.tap(find.byKey(const Key('entry:z.txt')));
    await pumpUntilFound(tester, find.text('3 selected'));
    await tester.tap(find.byKey(const Key('entry:y.txt')));
    await pumpUntilFound(tester, find.text('2 selected'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
    await tester.tap(find.byKey(const Key('deleteSelected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmButton')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:x.txt')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:y.txt')));
    // z.txt was outside the shrunk range, so it is still there.
    await pumpUntilFound(tester, find.byKey(const Key('entry:z.txt')));

    await openEntry(tester, find.byKey(const Key('entry:Photos')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/plans.txt')));

    await tester.tap(find.byKey(const Key('openSettings')));
    await pumpUntilFound(tester, find.text('This browser'));

    await expectLater(environment.browser!.unlock('wrong password'), throwsA(isA<RcloneException>()));
    await environment.browser!.unlock('browser password');
    expect((await environment.vault.status()).vaultRemote, 'vault');
    await environment.browser!.forget();
  });
}

/// tester.enterText goes through a fake text input that the browser's real one bypasses.
Future<void> setText(WidgetTester tester, Finder field, String text) async {
  tester.widget<TextField>(field).controller!.text = text;
  await tester.pump();
}
