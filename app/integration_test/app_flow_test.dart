import 'dart:io';

import 'package:cryptdrive/src/app.dart';
import 'package:cryptdrive/src/core/bootstrap.dart';
import 'package:cryptdrive/src/state/providers.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    // A mouse selects a row on click and opens it on double click; on a phone a tap
    // opens, so the pointer-and-keyboard blocks below only run on a desktop.
    final desktop =
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
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
    // Creating the vault writes the rclone config and lists it once; on a freshly
    // booted emulator that outlasts the default wait.
    await pumpUntilFound(tester, find.text('This folder is empty.'), timeout: const Duration(minutes: 2));
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

    if (desktop) {
      // The Drive keymap, end to end: dialogs, chord, settings, clipboard, undo.
      await tester.tap(find.byKey(const Key('entry:a.txt')));
      await settleCheck(tester);
      await pressWithAlt(tester, LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter);
      await pumpUntilFound(tester, find.text('Properties'));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await pressWithControl(tester, LogicalKeyboardKey.slash, PhysicalKeyboardKey.slash);
      await pumpUntilFound(tester, find.text('Keyboard shortcuts'));
      await tester.tap(find.byKey(const Key('closeShortcuts')));
      await tester.pumpAndSettle();

      // Alt+C then F is Drive's New folder chord.
      await pressWithAlt(tester, LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC);
      await pressKey(tester, LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF);
      await pumpUntilFound(tester, find.byKey(const Key('askTextField')));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await pressWithControlShift(tester, LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS);
      await pumpUntilFound(tester, find.byKey(const Key('exportRcloneConf')));
      await tester.tap(find.byKey(const Key('openFiles')));
      await pumpUntilFound(tester, find.byKey(const Key('entry:a.txt')));

      // Type-ahead jumps the selection; Shift+Space toggles it; Home/End pick the ends.
      await tester.tap(find.byKey(const Key('entry:a.txt')));
      await settleCheck(tester);
      await pressKey(tester, LogicalKeyboardKey.keyB, PhysicalKeyboardKey.keyB);
      await settleCheck(tester);
      expect(
        find.descendant(of: find.byKey(const Key('entry:b.txt')), matching: find.byKey(const ValueKey('selected'))),
        findsOneWidget,
      );
      await pressWithShift(tester, LogicalKeyboardKey.space, PhysicalKeyboardKey.space);
      await pumpUntilGone(tester, find.byKey(const Key('selectionCount')));
      await pressKey(tester, LogicalKeyboardKey.end, PhysicalKeyboardKey.end);
      await pumpUntilFound(tester, find.text('1 selected'));
      await pressKey(tester, LogicalKeyboardKey.home, PhysicalKeyboardKey.home);
      await pumpUntilFound(tester, find.text('1 selected'));

      await tester.tap(find.byKey(const Key('entry:a.txt')));
      await settleCheck(tester);
      // Copying items and paths: the platform channel is intercepted so the test
      // never reaches GTK's clipboard, which segfaults under a headless compositor
      // (no seat, so Gdk has no data device).
      final clipboard = <String>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add((call.arguments as Map)['text'] as String);
        return null;
      });
      await pressWithControlShift(tester, LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC);
      await pumpUntilFound(tester, find.text('Copied 1 title'));
      await pressWithControlAlt(tester, LogicalKeyboardKey.keyL, PhysicalKeyboardKey.keyL);
      await pumpUntilFound(tester, find.text('Copied 1 path'));
      expect(clipboard, ['a.txt', 'a.txt']);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);

      // Sharing only fails politely where the platform has no share sheet.
      if (defaultTargetPlatform == TargetPlatform.linux) {
        await pressWithControlAlt(tester, LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA);
        await pumpUntilFound(tester, find.text('This platform has no share sheet: use Save decrypted copies instead.'));
      }

      // Alt+G then I puts the keyboard back on the list, so an arrow moves the selection.
      await pressWithAlt(tester, LogicalKeyboardKey.keyG, PhysicalKeyboardKey.keyG);
      await pressKey(tester, LogicalKeyboardKey.keyI, PhysicalKeyboardKey.keyI);
      await pressKey(tester, LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown);
      await pumpUntilFound(tester, find.text('1 selected'));
      await tester.tap(find.byKey(const Key('clearSelection')));
      await pumpUntilGone(tester, find.byKey(const Key('selectionCount')));

      // Ctrl+F moves focus to the search field, and the results are selectable.
      await pressWithControl(tester, LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('searchField')), 'plans');
      await pumpUntilFound(tester, find.byKey(const Key('result:Photos/plans.txt')));
      await tester.tap(find.byTooltip('Clear'));
      await pumpUntilFound(tester, find.byKey(const Key('entry:a.txt')));

      // Back and forward walk the folder history.
      await openEntry(tester, find.byKey(const Key('entry:Photos')));
      await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/plans.txt')));
      await pressWithAlt(tester, LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
      await pumpUntilFound(tester, find.byKey(const Key('entry:a.txt')));
      await pressWithAlt(tester, LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
      await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/plans.txt')));
      await tester.tap(find.text('Vault'));
      await pumpUntilFound(tester, find.byKey(const Key('entry:a.txt')));

      // Copy into the folder, undo it, redo it, then delete the copy.
      await tester.tap(find.byKey(const Key('entry:a.txt')));
      await settleCheck(tester);
      await pressWithControl(tester, LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC);
      await openEntry(tester, find.byKey(const Key('entry:Photos')));
      await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/plans.txt')));
      await pressWithControl(tester, LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV);
      await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/a.txt')));
      await pressWithControl(tester, LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ);
      await pumpUntilGone(tester, find.byKey(const Key('entry:Photos/a.txt')));
      await pressWithControl(tester, LogicalKeyboardKey.keyY, PhysicalKeyboardKey.keyY);
      await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/a.txt')));
      await tester.tap(find.byKey(const Key('entry:Photos/a.txt')));
      await settleCheck(tester);
      await tester.tap(find.byKey(const Key('deleteSelected')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmButton')));
      await pumpUntilGone(tester, find.byKey(const Key('entry:Photos/a.txt')));

      // Cut and paste moves instead of copying; undo brings the file back.
      await tester.tap(find.text('Vault'));
      await pumpUntilFound(tester, find.byKey(const Key('entry:b.txt')));
      await tester.tap(find.byKey(const Key('entry:b.txt')));
      await settleCheck(tester);
      await pressWithControl(tester, LogicalKeyboardKey.keyX, PhysicalKeyboardKey.keyX);
      await openEntry(tester, find.byKey(const Key('entry:Photos')));
      await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/plans.txt')));
      await pressWithControl(tester, LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV);
      await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/b.txt')));
      await pressWithControl(tester, LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ);
      await pumpUntilGone(tester, find.byKey(const Key('entry:Photos/b.txt')));
      await tester.tap(find.text('Vault'));
      await pumpUntilFound(tester, find.byKey(const Key('entry:b.txt')));
    }
    await tester.longPress(find.byKey(const Key('entry:a.txt')));
    await pumpUntilFound(tester, find.text('1 selected'));
    await controlClick(tester, find.byKey(const Key('entry:b.txt')));
    await tester.tap(find.byKey(const Key('select:c.txt')));
    await pumpUntilFound(tester, find.text('3 selected'));
    await tester.tap(find.byKey(const Key('clearSelection')));
    await pumpUntilGone(tester, find.byKey(const Key('selectionCount')));
    if (desktop) {
      // Drive keys: a click selects, arrows walk the selection, Shift+arrows extend it.
      Finder selectedIcon(String path) =>
          find.descendant(of: find.byKey(Key('entry:$path')), matching: find.byKey(const ValueKey('selected')));
      await tester.tap(find.byKey(const Key('entry:a.txt')));
      await settleCheck(tester);
      expect(selectedIcon('a.txt'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown, physicalKey: PhysicalKeyboardKey.arrowDown);
      await settleCheck(tester);
      expect(selectedIcon('b.txt'), findsOneWidget);
      expect(selectedIcon('a.txt'), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown, physicalKey: PhysicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
      await pumpUntilFound(tester, find.text('2 selected'));
      await tester.tap(find.byKey(const Key('clearSelection')));
      await pumpUntilGone(tester, find.byKey(const Key('selectionCount')));
      // Enter opens the row the selection sits on.
      await tester.tap(find.byKey(const Key('entry:Photos')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter, physicalKey: PhysicalKeyboardKey.enter);
      await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/plans.txt')));
      await tester.tap(find.text('Vault'));
      await pumpUntilFound(tester, find.byKey(const Key('entry:a.txt')));
      // Shift-click picks the range from the clicked row, even with nothing selected yet.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
      await tester.tap(find.byKey(const Key('entry:a.txt')));
      await pumpUntilFound(tester, find.text('1 selected'));
      await tester.tap(find.byKey(const Key('entry:c.txt')));
      await pumpUntilFound(tester, find.text('3 selected'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft, physicalKey: PhysicalKeyboardKey.shiftLeft);
    } else {
      // Touch has no Shift-click: long press starts the selection, taps add to it.
      await tester.longPress(find.byKey(const Key('entry:a.txt')));
      await pumpUntilFound(tester, find.text('1 selected'));
      await controlClick(tester, find.byKey(const Key('entry:b.txt')));
      await tester.tap(find.byKey(const Key('select:c.txt')));
      await pumpUntilFound(tester, find.text('3 selected'));
    }
    await tester.tap(find.byKey(const Key('moveSelected')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('askTextField')), 'Photos');
    await tester.tap(find.byKey(const Key('askTextConfirm')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:c.txt')));
    await pumpUntilGone(tester, find.byKey(const Key('selectionCount')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos')));

    await openEntry(tester, find.byKey(const Key('entry:Photos')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/plans.txt')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:Photos/c.txt')));
    await tester.longPress(find.byKey(const Key('entry:Photos/a.txt')));
    await pumpUntilFound(tester, find.text('1 selected'));
    await controlClick(tester, find.byKey(const Key('entry:Photos/b.txt')));
    await controlClick(tester, find.byKey(const Key('entry:Photos/c.txt')));
    await pumpUntilFound(tester, find.text('3 selected'));
    await tester.tap(find.byKey(const Key('clearSelection')));
    await pumpUntilGone(tester, find.byKey(const Key('selectionCount')));
    // Touch multi-selection: long press, then drag, the range following the finger
    // and shrinking when it comes back up.
    Finder row(String name) => find.byKey(Key('entry:Photos/$name'));
    final drag = await tester.startGesture(tester.getCenter(row('a.txt')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await pumpUntilFound(tester, find.text('1 selected'));
    await drag.moveTo(tester.getCenter(row('c.txt')));
    await tester.pump();
    await pumpUntilFound(tester, find.text('3 selected'));
    await drag.moveTo(tester.getCenter(row('b.txt')));
    await tester.pump();
    await pumpUntilFound(tester, find.text('2 selected'));
    await drag.moveTo(tester.getCenter(row('c.txt')));
    await tester.pump();
    await pumpUntilFound(tester, find.text('3 selected'));
    await drag.up();
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
    await tester.longPress(find.byKey(const Key('entry:dropped-one.txt')));
    await pumpUntilFound(tester, find.text('1 selected'));
    await controlClick(tester, find.byKey(const Key('entry:dropped-two.txt')));
    await pumpUntilFound(tester, find.text('2 selected'));
    await tester.tap(find.byKey(const Key('deleteSelected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmButton')));
    await pumpUntilGone(tester, find.byKey(const Key('entry:dropped-one.txt')));

    // Dropping a folder uploads its whole tree, empty folders included.
    final tree = Directory(p.join(dropDir.path, 'dropped-tree'))..createSync();
    File(p.join(tree.path, 'top.txt')).writeAsStringSync('top of the tree');
    Directory(p.join(tree.path, 'inner')).createSync();
    File(p.join(tree.path, 'inner', 'deep.txt')).writeAsStringSync('deep down');
    Directory(p.join(tree.path, 'inner', 'empty')).createSync();
    dropTarget.onDragDone!(
      DropDoneDetails(
        files: [DropItemDirectory(tree.path, const [])],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await pumpUntilFound(tester, find.byKey(const Key('entry:dropped-tree')));
    await openEntry(tester, find.byKey(const Key('entry:dropped-tree')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:dropped-tree/top.txt')));
    await openEntry(tester, find.byKey(const Key('entry:dropped-tree/inner')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:dropped-tree/inner/deep.txt')));
    await pumpUntilFound(tester, find.byKey(const Key('entry:dropped-tree/inner/empty')));
    final inner = await environment.vault.list('dropped-tree/inner');
    expect(inner.map((entry) => (entry.name, entry.isDir)), containsAll([('deep.txt', false), ('empty', true)]));
    final decryptedDeep = await environment.vault.decryptToTemp(inner.firstWhere((entry) => !entry.isDir));
    expect(await decryptedDeep.readAsString(), 'deep down');
    await tester.tap(find.text('Vault'));
    await pumpUntilFound(tester, find.byKey(const Key('entry:dropped-tree')));

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
