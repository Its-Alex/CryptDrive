import 'dart:io';

import 'package:cryptdrive/src/app.dart';
import 'package:cryptdrive/src/core/bootstrap.dart';
import 'package:cryptdrive/src/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// MVP acceptance flow on a real device/desktop, with a local folder standing in
/// for Google Drive: set up, create a vault, upload, browse, CRUD, preview, export.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('onboarding, upload, browse, CRUD and preview', (tester) async {
    final support = await getApplicationSupportDirectory();
    final runDir = Directory(p.join(support.path, 'integration-test-${DateTime.now().millisecondsSinceEpoch}'));
    final directories = AppDirectories(
      support: Directory(p.join(runDir.path, 'support')),
      temporary: Directory(p.join(runDir.path, 'tmp')),
    );
    final container = ProviderContainer(
      retry: noRetry,
      overrides: [appDirectoriesProvider.overrideWithValue(directories)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const CryptDriveApp()));
    await pumpUntilFound(tester, find.text('Set up CryptDrive'));

    // Real keystore: the config password went to flutter_secure_storage, the config is encrypted on disk.
    final environment = container.read(environmentProvider).requireValue;
    expect(await environment.secrets.readConfigPassword(), isNotEmpty);

    await tester.tap(find.byKey(const Key('chooseLocalFolder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('useLocalFolder')));
    await pumpUntilFound(tester, find.byKey(const Key('vaultPasswordField')));

    final vaultFolder = p.join(runDir.path, 'fake-google-drive', 'CryptDrive');
    await tester.enterText(find.byKey(const Key('vaultFolderField')), vaultFolder);
    await tester.enterText(find.byKey(const Key('vaultPasswordField')), 'correct horse battery staple');
    await tester.enterText(find.byKey(const Key('vaultPasswordConfirmationField')), 'correct horse battery staple');
    await tapVisible(tester, find.byKey(const Key('vaultSubmit')));
    await pumpUntilFound(tester, find.text('This folder is empty.'));
    expect(environment.configFile.readAsStringSync(), contains('RCLONE_ENCRYPT_V0:'));

    // Upload, as the file picker / share target does once the file is staged locally.
    final staged = File(p.join(runDir.path, 'staging', 'notes.txt'));
    await staged.create(recursive: true);
    await staged.writeAsString('meet at the old oak tree');
    await environment.vault.upload(staged, '');
    await tester.tap(find.byTooltip('Refresh'));
    await pumpUntilFound(tester, find.byKey(const Key('entry:notes.txt')));

    for (final stored in Directory(vaultFolder).listSync(recursive: true)) {
      expect(p.basename(stored.path), isNot(contains('notes')));
      if (stored is File) expect(String.fromCharCodes(stored.readAsBytesSync()).contains('oak tree'), isFalse);
    }

    await tester.tap(find.byKey(const Key('addButton')));
    await pumpUntilFound(tester, find.byKey(const Key('newFolder')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('newFolder')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('askTextField')), 'Photos');
    await tester.tap(find.byKey(const Key('askTextConfirm')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos')));

    await chooseMenuAction(tester, 'notes.txt', 'Preview');
    await pumpUntilFound(tester, find.textContaining('meet at the old oak tree'));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await chooseMenuAction(tester, 'notes.txt', 'Rename');
    await tester.enterText(find.byKey(const Key('askTextField')), 'plans.txt');
    await tester.tap(find.byKey(const Key('askTextConfirm')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:plans.txt')));

    await chooseMenuAction(tester, 'plans.txt', 'Move');
    await tester.enterText(find.byKey(const Key('askTextField')), 'Photos');
    await tester.tap(find.byKey(const Key('askTextConfirm')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:plans.txt')));

    await tester.tap(find.byKey(const Key('entry:Photos')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/plans.txt')));

    final decrypted = await environment.vault.decryptToTemp((await environment.vault.list('Photos')).single);
    expect(await decrypted.readAsString(), 'meet at the old oak tree');

    await chooseMenuAction(tester, 'Photos/plans.txt', 'Delete');
    await tester.tap(find.byKey(const Key('confirmButton')));
    await pumpUntilFound(tester, find.text('This folder is empty.'));

    await tester.tap(find.text('Vault'));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos')));
    await tester.enterText(find.byKey(const Key('searchField')), 'phot');
    await pumpUntilFound(tester, find.byKey(const Key('result:Photos')));
    await tester.tap(find.byTooltip('Clear'));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos')));

    await tester.tap(find.byKey(const Key('openRecent')));
    await pumpUntilFound(tester, find.text('Files you open or upload show up here.'));
    await tester.tap(find.byKey(const Key('openSettings')));
    await pumpUntilFound(tester, find.textContaining('rclone v1.76.0'));
    final exported = await environment.vault.exportRcloneConf();
    expect(exported, contains('[vault]'));

    await environment.shutdown();
    expect(Directory(p.join(directories.temporary.path, 'cryptdrive-opened')).existsSync(), isFalse);
    await environment.secrets.deleteConfigPassword();
    await runDir.delete(recursive: true);
  });
}

/// Closes the on-screen keyboard first: on phones it shrinks the viewport over the target.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Future<void> chooseMenuAction(WidgetTester tester, String entryPath, String action) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('menu:$entryPath')));
  await pumpUntilFound(tester, find.text(action));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(action).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(action).last);
  await tester.pumpAndSettle();
}

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

Future<void> pumpUntilGone(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder to disappear');
}
