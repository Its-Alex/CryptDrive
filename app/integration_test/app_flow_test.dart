import 'dart:io';

import 'package:cryptdrive/src/app.dart';
import 'package:cryptdrive/src/core/bootstrap.dart';
import 'package:cryptdrive/src/state/providers.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'helpers.dart';

/// MVP acceptance flow on a real device/desktop, with a local folder standing in
/// for Google Drive: set up, create a vault, upload, browse, CRUD, preview, export.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('onboarding, upload, browse, CRUD and preview', (tester) async {
    final support = await getApplicationSupportDirectory();
    // A fixed path: if Android recreates the activity, the test reruns in a process whose
    // native library is already initialized with this config path.
    final runDir = Directory(p.join(support.path, 'integration-test'));
    if (await runDir.exists()) await runDir.delete(recursive: true);
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
    final startedEnvironment = await container.read(environmentProvider.future);
    // Remotes left in the native library's memory by a previous run in the same process.
    final leftovers = (await startedEnvironment.rclone.call('config/listremotes'))['remotes'] as List? ?? [];
    for (final remote in leftovers) {
      await startedEnvironment.rclone.call('config/delete', {'name': remote});
    }
    container.invalidate(setupStatusProvider);
    await pumpUntilFound(tester, find.text('Set up CryptDrive'));

    // Real keystore: the config password went to flutter_secure_storage, the config is encrypted on disk.
    final environment = container.read(environmentProvider).requireValue;
    expect(await environment.secrets!.readConfigPassword(), isNotEmpty);

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
    expect(environment.configFile!.readAsStringSync(), contains('RCLONE_ENCRYPT_V0:'));

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

    // Multiple selection: long-press starts it, taps add to it, then one move for all.
    for (final name in ['a.txt', 'b.txt', 'c.txt']) {
      final file = File(p.join(runDir.path, 'staging', name));
      await file.writeAsString('file $name');
      await environment.vault.upload(file, '');
    }
    await tester.tap(find.byTooltip('Refresh'));
    await pumpUntilFound(tester, find.byKey(const Key('entry:c.txt')));
    await tester.longPress(find.byKey(const Key('entry:a.txt')));
    await pumpUntilFound(tester, find.text('1 selected'));
    await tester.tap(find.byKey(const Key('entry:b.txt')));
    await tester.tap(find.byKey(const Key('select:c.txt')));
    await pumpUntilFound(tester, find.text('3 selected'));
    await tester.tap(find.byKey(const Key('moveSelected')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('askTextField')), 'Photos');
    await tester.tap(find.byKey(const Key('askTextConfirm')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:c.txt')));
    await pumpUntilGone(tester, find.byKey(const Key('selectionCount')));

    await tester.tap(find.byKey(const Key('entry:Photos')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/plans.txt')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/c.txt')));
    await tester.longPress(find.byKey(const Key('entry:Photos/a.txt')));
    await pumpUntilFound(tester, find.text('1 selected'));
    await tester.tap(find.byKey(const Key('entry:Photos/b.txt')));
    await tester.tap(find.byKey(const Key('entry:Photos/c.txt')));
    await pumpUntilFound(tester, find.text('3 selected'));
    await tester.tap(find.byKey(const Key('deleteSelected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmButton')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:Photos/a.txt')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:Photos/c.txt')));
    expect(find.byKey(const Key('entry:Photos/plans.txt')), findsOneWidget);

    final decrypted = await environment.vault.decryptToTemp((await environment.vault.list('Photos')).single);
    expect(await decrypted.readAsString(), 'meet at the old oak tree');

    await chooseMenuAction(tester, 'Photos/plans.txt', 'Delete');
    await tester.tap(find.byKey(const Key('confirmButton')));
    await pumpUntilFound(tester, find.text('This folder is empty.'));

    await tester.tap(find.text('Vault'));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos')));
    await tester.enterText(find.byKey(const Key('searchField')), 'phot');
    await pumpUntilFound(tester, find.byKey(const Key('result:Photos')));
    // Search results are selectable too, and the bulk actions reach their folders.
    await tester.longPress(find.byKey(const Key('result:Photos')));
    await pumpUntilFound(tester, find.text('1 selected'));
    await tester.tap(find.byKey(const Key('deleteSelected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmButton')));
    await pumpUntilGone(tester, find.byKey(const Key('result:Photos')));
    await pumpUntilGone(tester, find.byKey(const Key('selectionCount')));
    await tester.tap(find.byTooltip('Clear'));
    await pumpUntilGone(tester, find.byKey(const Key('entry:Photos')));

    // Drag and drop: the OS hands over paths, staged and uploaded like a picked file.
    final dropDir = Directory(p.join(runDir.path, 'dropped'))..createSync();
    final first = File(p.join(dropDir.path, 'dropped-one.txt'))..writeAsStringSync('first drop');
    final second = File(p.join(dropDir.path, 'dropped-two.txt'))..writeAsStringSync('second drop');
    final dropTarget = tester.widget<DropTarget>(find.byType(DropTarget));
    dropTarget.onDragEntered!(DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero));
    await tester.pump();
    expect(find.byKey(const Key('dropOverlay')), findsOneWidget);
    dropTarget.onDragExited!(DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero));
    await tester.pump();
    expect(find.byKey(const Key('dropOverlay')), findsNothing);
    dropTarget.onDragDone!(
      DropDoneDetails(
        files: [DropItemFile(first.path), DropItemFile(second.path)],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await pumpUntilFound(tester, find.byKey(const Key('entry:dropped-one.txt')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:dropped-two.txt')));
    await tester.tap(find.byKey(const Key('startSelecting')));
    await pumpUntilFound(tester, find.text('0 selected'));
    await tester.tap(find.byKey(const Key('entry:dropped-one.txt')));
    await pumpUntilFound(tester, find.text('1 selected'));
    await tester.tap(find.byKey(const Key('entry:dropped-two.txt')));
    await pumpUntilFound(tester, find.text('2 selected'));
    await tester.tap(find.byKey(const Key('deleteSelected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmButton')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:dropped-one.txt')));

    await tester.tap(find.byKey(const Key('openRecent')));
    await pumpUntilFound(tester, find.text('Files you open or upload show up here.'));
    await tester.tap(find.byKey(const Key('openSettings')));
    await pumpUntilFound(tester, find.textContaining('rclone v1.76.0'));
    final exported = await environment.vault.exportRcloneConf();
    expect(exported, contains('[vault]'));

    await environment.shutdown();
    expect(Directory(p.join(directories.temporary.path, 'cryptdrive-opened')).existsSync(), isFalse);
    await environment.secrets!.deleteConfigPassword();
    await runDir.delete(recursive: true);
  });
}
