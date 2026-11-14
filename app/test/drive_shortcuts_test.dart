import 'package:cryptdrive/src/core/drive_shortcuts.dart';
import 'package:cryptdrive/src/core/vault_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records which sink method the controller picked, so dispatch is testable
/// without a widget.
class _Recorder implements DriveActionSink {
  final calls = <String>[];

  @override
  void moveToFolder() => calls.add('moveToFolder');
  @override
  void cut() => calls.add('cut');
  @override
  void copy() => calls.add('copy');
  @override
  void paste() => calls.add('paste');
  @override
  void copyTitles() => calls.add('copyTitles');
  @override
  void copyPaths() => calls.add('copyPaths');
  @override
  void shareSelection() => calls.add('shareSelection');
  @override
  void undo() => calls.add('undo');
  @override
  void redo() => calls.add('redo');
  @override
  void openCurrent() => calls.add('openCurrent');
  @override
  void renameCurrent() => calls.add('renameCurrent');
  @override
  void deleteSelection() => calls.add('deleteSelection');
  @override
  void previewCurrent() => calls.add('previewCurrent');
  @override
  void toggleCurrent() => calls.add('toggleCurrent');
  @override
  void selectAll() => calls.add('selectAll');
  @override
  void clearSelection() => calls.add('clearSelection');
  @override
  void moveRow(int delta, {required bool extend}) => calls.add('moveRow($delta,$extend)');
  @override
  void moveFocus(int delta) => calls.add('moveFocus($delta)');
  @override
  void selectEdge({required bool last, required bool extend}) => calls.add('selectEdge($last,$extend)');
  @override
  void upOneFolder() => calls.add('upOneFolder');
  @override
  void goBack() => calls.add('goBack');
  @override
  void goForward() => calls.add('goForward');
  @override
  void refresh() => calls.add('refresh');
  @override
  void focusSearch() => calls.add('focusSearch');
  @override
  void newFolder() => calls.add('newFolder');
  @override
  void upload() => calls.add('upload');
  @override
  void openCreateMenu() => calls.add('openCreateMenu');
  @override
  void openSettings() => calls.add('openSettings');
  @override
  void showShortcutList() => calls.add('showShortcutList');
  @override
  void focusList() => calls.add('focusList');
  @override
  void showProperties() => calls.add('showProperties');
  @override
  void showContextMenu() => calls.add('showContextMenu');
}

VaultEntry _entry(String path, {bool isDir = false}) =>
    VaultEntry(path: path, name: path.split('/').last, isDir: isDir, size: 10, modTime: null);

void main() {
  group('keymap', () {
    test('every binding resolves to its own action with its own modifiers', () {
      for (final binding in driveKeyBindings) {
        expect(
          resolveDriveAction(key: binding.key, primary: binding.primary, alt: binding.alt, shift: binding.shift),
          binding.action,
          reason: '${driveBindingLabel(binding)} should be ${binding.action}',
        );
      }
    });

    test('an unbound modifier combination stays unbound', () {
      // Ctrl+Shift+V is Drive's "paste as shortcut", which has no equivalent.
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyV, primary: true, shift: true), isNull);
      // Drive's star shortcut has nothing to act on.
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyS, primary: true, alt: true), isNull);
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyR, primary: true, alt: true), isNull);
      // Plain letters belong to type-ahead, not to a shortcut.
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyN), isNull);
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyZ), isNull);
    });

    test('Drive\'s item URL and share shortcuts have a vault equivalent', () {
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyL, primary: true, alt: true), DriveAction.copyPaths);
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyA, primary: true, alt: true), DriveAction.shareSelection);
    });

    test('the horizontal arrows walk the list like the vertical ones', () {
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowRight), DriveAction.rowDown);
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowLeft), DriveAction.rowUp);
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowRight, shift: true), DriveAction.extendDown);
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowLeft, shift: true), DriveAction.extendUp);
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowRight, primary: true), DriveAction.focusDown);
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowLeft, primary: true), DriveAction.focusUp);
    });

    test('the Finder aliases land on the same actions', () {
      expect(resolveDriveAction(key: LogicalKeyboardKey.f3), DriveAction.focusSearch);
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyI, primary: true), DriveAction.properties);
      expect(resolveDriveAction(key: LogicalKeyboardKey.bracketLeft, primary: true), DriveAction.goBack);
      expect(resolveDriveAction(key: LogicalKeyboardKey.bracketRight, primary: true), DriveAction.goForward);
    });

    test('Ctrl+X, Ctrl+C and Ctrl+V act on items; their Shift forms do not', () {
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyX, primary: true), DriveAction.cut);
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyC, primary: true), DriveAction.copy);
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyV, primary: true), DriveAction.paste);
      expect(resolveDriveAction(key: LogicalKeyboardKey.keyC, primary: true, shift: true), DriveAction.copyTitles);
    });

    test('both of Drive\'s delete keys land on delete', () {
      expect(resolveDriveAction(key: LogicalKeyboardKey.delete), DriveAction.delete);
      expect(resolveDriveAction(key: LogicalKeyboardKey.delete, shift: true), DriveAction.delete);
      expect(resolveDriveAction(key: LogicalKeyboardKey.numberSign, shift: true), DriveAction.delete);
    });

    test('arrows select, extend with Shift and move focus with the primary modifier', () {
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowDown), DriveAction.rowDown);
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowDown, shift: true), DriveAction.extendDown);
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowDown, primary: true), DriveAction.focusDown);
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowUp), DriveAction.rowUp);
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowUp, shift: true), DriveAction.extendUp);
      expect(resolveDriveAction(key: LogicalKeyboardKey.arrowUp, primary: true), DriveAction.focusUp);
      expect(resolveDriveAction(key: LogicalKeyboardKey.home), DriveAction.rowFirst);
      expect(resolveDriveAction(key: LogicalKeyboardKey.end), DriveAction.rowLast);
    });

    test('the move and file toolkits are all bound', () {
      final expected = <(LogicalKeyboardKey, bool, bool, bool, DriveAction)>[
        (LogicalKeyboardKey.keyM, true, true, false, DriveAction.moveToFolder),
        (LogicalKeyboardKey.keyP, true, true, false, DriveAction.preview),
        (LogicalKeyboardKey.keyA, true, false, false, DriveAction.selectAll),
        (LogicalKeyboardKey.escape, false, false, false, DriveAction.clearSelection),
        (LogicalKeyboardKey.f2, false, false, false, DriveAction.rename),
        (LogicalKeyboardKey.f5, false, false, false, DriveAction.refresh),
        (LogicalKeyboardKey.enter, false, false, false, DriveAction.open),
        (LogicalKeyboardKey.enter, true, false, false, DriveAction.open),
        (LogicalKeyboardKey.enter, false, true, false, DriveAction.properties),
        (LogicalKeyboardKey.f10, false, false, true, DriveAction.contextMenu),
        (LogicalKeyboardKey.keyA, false, true, false, DriveAction.contextMenu),
        (LogicalKeyboardKey.keyN, false, true, false, DriveAction.createMenu),
        (LogicalKeyboardKey.keyN, true, false, true, DriveAction.newFolder),
        (LogicalKeyboardKey.keyS, true, false, true, DriveAction.settings),
        (LogicalKeyboardKey.keyF, true, false, false, DriveAction.focusSearch),
        (LogicalKeyboardKey.slash, false, false, false, DriveAction.focusSearch),
        (LogicalKeyboardKey.slash, true, false, false, DriveAction.shortcutList),
        (LogicalKeyboardKey.arrowUp, false, true, false, DriveAction.upOneFolder),
        (LogicalKeyboardKey.backspace, false, false, false, DriveAction.upOneFolder),
        (LogicalKeyboardKey.arrowLeft, false, true, false, DriveAction.goBack),
        (LogicalKeyboardKey.arrowRight, false, true, false, DriveAction.goForward),
        (LogicalKeyboardKey.space, false, false, false, DriveAction.preview),
        (LogicalKeyboardKey.space, false, false, true, DriveAction.toggleSelection),
        (LogicalKeyboardKey.keyZ, true, false, false, DriveAction.undo),
        (LogicalKeyboardKey.keyY, true, false, false, DriveAction.redo),
      ];
      for (final (key, primary, alt, shift, action) in expected) {
        expect(
          resolveDriveAction(key: key, primary: primary, alt: alt, shift: shift),
          action,
          reason: '${key.keyLabel} primary=$primary alt=$alt shift=$shift',
        );
      }
    });

    test('every action but the chord-only upload has a binding', () {
      final bound = {for (final binding in driveKeyBindings) binding.action};
      for (final action in DriveAction.values) {
        // These two are chord-only, so they have no single binding.
        if (action == DriveAction.upload || action == DriveAction.focusList) continue;
        expect(bound, contains(action), reason: '$action has no key');
      }
    });

    test('every action has a label and every binding a non-empty key label', () {
      for (final action in DriveAction.values) {
        expect(driveActionLabel(action), isNotEmpty);
      }
      for (final binding in driveKeyBindings) {
        final label = driveBindingLabel(binding);
        expect(label, isNotEmpty);
        if (binding.primary) expect(label, contains('Ctrl'));
        if (binding.alt) expect(label, contains('Alt'));
        if (binding.shift) expect(label, contains('Shift'));
        expect(
          label,
          endsWith(switch (binding.key) {
            LogicalKeyboardKey.escape => 'Esc',
            LogicalKeyboardKey.arrowDown => '↓',
            LogicalKeyboardKey.arrowUp => '↑',
            LogicalKeyboardKey.arrowLeft => '←',
            LogicalKeyboardKey.arrowRight => '→',
            LogicalKeyboardKey.delete => 'Del',
            LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => 'Enter',
            LogicalKeyboardKey.space => 'Space',
            LogicalKeyboardKey.backspace => 'Backspace',
            _ => binding.key.keyLabel,
          }),
        );
      }
    });
  });

  group('dispatch', () {
    test('each action calls the matching sink method', () {
      const expected = {
        DriveAction.moveToFolder: 'moveToFolder',
        DriveAction.cut: 'cut',
        DriveAction.copy: 'copy',
        DriveAction.paste: 'paste',
        DriveAction.copyTitles: 'copyTitles',
        DriveAction.copyPaths: 'copyPaths',
        DriveAction.shareSelection: 'shareSelection',
        DriveAction.undo: 'undo',
        DriveAction.redo: 'redo',
        DriveAction.open: 'openCurrent',
        DriveAction.rename: 'renameCurrent',
        DriveAction.delete: 'deleteSelection',
        DriveAction.preview: 'previewCurrent',
        DriveAction.toggleSelection: 'toggleCurrent',
        DriveAction.selectAll: 'selectAll',
        DriveAction.clearSelection: 'clearSelection',
        DriveAction.rowDown: 'moveRow(1,false)',
        DriveAction.rowUp: 'moveRow(-1,false)',
        DriveAction.extendDown: 'moveRow(1,true)',
        DriveAction.extendUp: 'moveRow(-1,true)',
        DriveAction.focusDown: 'moveFocus(1)',
        DriveAction.focusUp: 'moveFocus(-1)',
        DriveAction.rowFirst: 'selectEdge(false,false)',
        DriveAction.rowLast: 'selectEdge(true,false)',
        DriveAction.upOneFolder: 'upOneFolder',
        DriveAction.goBack: 'goBack',
        DriveAction.goForward: 'goForward',
        DriveAction.refresh: 'refresh',
        DriveAction.focusSearch: 'focusSearch',
        DriveAction.newFolder: 'newFolder',
        DriveAction.upload: 'upload',
        DriveAction.createMenu: 'openCreateMenu',
        DriveAction.settings: 'openSettings',
        DriveAction.shortcutList: 'showShortcutList',
        DriveAction.focusList: 'focusList',
        DriveAction.properties: 'showProperties',
        DriveAction.contextMenu: 'showContextMenu',
      };
      expect(expected.keys.toSet(), DriveAction.values.toSet(), reason: 'every action needs a dispatch case');
      for (final entry in expected.entries) {
        final recorder = _Recorder();
        DriveShortcutController(recorder).run(entry.key);
        expect(recorder.calls, [entry.value], reason: '${entry.key}');
      }
    });

    test('a bound key runs its action and consumes the event', () {
      final recorder = _Recorder();
      final controller = DriveShortcutController(recorder);
      expect(controller.handleKey(key: LogicalKeyboardKey.keyX, primary: true), isTrue);
      expect(controller.handleKey(key: LogicalKeyboardKey.keyV, primary: true), isTrue);
      expect(recorder.calls, ['cut', 'paste']);
    });

    test('an unbound key is left to the caller', () {
      final recorder = _Recorder();
      final controller = DriveShortcutController(recorder);
      expect(controller.handleKey(key: LogicalKeyboardKey.keyQ), isFalse);
      expect(controller.handleKey(key: LogicalKeyboardKey.keyV, primary: true, shift: true), isFalse);
      expect(recorder.calls, isEmpty);
    });
  });

  group('chords', () {
    final start = DateTime.utc(2026, 11, 14, 12);

    test('Alt+C arms and the second key picks the action', () {
      final recorder = _Recorder();
      final controller = DriveShortcutController(recorder, chord: ChordSession());
      expect(controller.handleKey(key: LogicalKeyboardKey.keyC, alt: true, now: start), isTrue);
      expect(recorder.calls, isEmpty, reason: 'the leader must not act yet');
      expect(controller.handleKey(key: LogicalKeyboardKey.keyF, now: start.add(const Duration(seconds: 1))), isTrue);
      expect(recorder.calls, ['newFolder']);
    });

    test('U and I both upload', () {
      for (final key in [LogicalKeyboardKey.keyU, LogicalKeyboardKey.keyI]) {
        final recorder = _Recorder();
        final controller = DriveShortcutController(recorder);
        controller.handleKey(key: LogicalKeyboardKey.keyC, alt: true, now: start);
        expect(controller.handleKey(key: key, now: start.add(const Duration(seconds: 1))), isTrue);
        expect(recorder.calls, ['upload']);
      }
    });

    test('a chord left alone expires instead of firing later', () {
      final recorder = _Recorder();
      final controller = DriveShortcutController(recorder);
      controller.handleKey(key: LogicalKeyboardKey.keyC, alt: true, now: start);
      expect(controller.handleKey(key: LogicalKeyboardKey.keyF, now: start.add(const Duration(seconds: 5))), isFalse);
      expect(controller.chord.isArmed, isFalse);
      expect(recorder.calls, isEmpty);
    });

    test('a key outside the chord cancels it', () {
      final recorder = _Recorder();
      final controller = DriveShortcutController(recorder);
      controller.handleKey(key: LogicalKeyboardKey.keyC, alt: true, now: start);
      expect(controller.handleKey(key: LogicalKeyboardKey.keyQ, now: start.add(const Duration(seconds: 1))), isFalse);
      expect(controller.chord.isArmed, isFalse);
      expect(recorder.calls, isEmpty);
    });

    test('Alt+G then I focuses the list', () {
      final recorder = _Recorder();
      final controller = DriveShortcutController(recorder);
      expect(controller.handleKey(key: LogicalKeyboardKey.keyG, alt: true, now: start), isTrue);
      expect(controller.handleKey(key: LogicalKeyboardKey.keyI, now: start.add(const Duration(seconds: 1))), isTrue);
      expect(recorder.calls, ['focusList']);
    });

    test('the create chord does not answer the focus chord key', () {
      final recorder = _Recorder();
      final controller = DriveShortcutController(recorder);
      controller.handleKey(key: LogicalKeyboardKey.keyC, alt: true, now: start);
      expect(controller.handleKey(key: LogicalKeyboardKey.keyG, now: start.add(const Duration(seconds: 1))), isFalse);
      expect(controller.chord.isArmed, isFalse);
      expect(recorder.calls, isEmpty);
    });
  });

  group('type-ahead', () {
    final start = DateTime.utc(2026, 11, 14, 12);

    test('characters accumulate into a lower-case prefix and expire', () {
      final buffer = TypeAheadBuffer();
      expect(buffer.add('P', start), 'p');
      expect(buffer.add('h', start.add(const Duration(milliseconds: 100))), 'ph');
      expect(buffer.add('o', start.add(const Duration(seconds: 2))), 'o', reason: 'the window resets the prefix');
      buffer.reset();
      expect(buffer.text, isEmpty);
    });

    test('matches the first name with the prefix, wrapping around', () {
      const names = ['alpha.txt', 'beta.txt', 'Photos', 'plans.txt'];
      expect(typeAheadMatch(names, 'p'), 2);
      expect(typeAheadMatch(names, 'pl'), 3);
      expect(typeAheadMatch(names, 'b'), 1);
      expect(typeAheadMatch(names, 'z'), isNull);
      expect(typeAheadMatch(names, ''), isNull);
      expect(typeAheadMatch(const [], 'a'), isNull);
    });

    test('starts after the current row and wraps', () {
      const names = ['alpha.txt', 'beta.txt', 'Photos', 'plans.txt'];
      expect(typeAheadMatch(names, 'p', after: 2), 3);
      expect(typeAheadMatch(names, 'a', after: 3), 0);
    });
  });

  group('clipboard and journal', () {
    test('the clipboard remembers whether it cut or copied', () {
      final cut = DriveClipboard(entries: [_entry('a.txt')], isCut: true);
      final copied = DriveClipboard(entries: [_entry('b.txt')], isCut: false);
      expect(cut.isCut, isTrue);
      expect(copied.isCut, isFalse);
      expect(copied.isEmpty, isFalse);
    });

    test('undo pops the newest operation and hands it to redo', () {
      final journal = UndoJournal();
      final move = VaultOperation(kind: VaultOperationKind.move, to: 'Photos', entries: [_entry('a.txt')]);
      final copy = VaultOperation(kind: VaultOperationKind.copy, to: 'Docs', entries: [_entry('b.txt')]);
      journal.record(move);
      journal.record(copy);
      expect(journal.undo(), copy);
      expect(journal.undo(), move);
      expect(journal.undo(), isNull);
      expect(journal.redo(), move);
      expect(journal.redo(), copy);
      expect(journal.redo(), isNull);
    });

    test('a new operation drops the redo stack', () {
      final journal = UndoJournal();
      journal.record(VaultOperation(kind: VaultOperationKind.move, to: 'A', entries: [_entry('a')]));
      journal.undo();
      expect(journal.canRedo, isTrue);
      journal.record(VaultOperation(kind: VaultOperationKind.copy, to: 'B', entries: [_entry('b')]));
      expect(journal.canRedo, isFalse);
    });

    test('undo and redo report emptiness', () {
      final journal = UndoJournal();
      expect(journal.canUndo, isFalse);
      expect(journal.undo(), isNull);
      expect(journal.canRedo, isFalse);
      expect(journal.redo(), isNull);
    });

    test('a copy lands under the destination folder, keeping its name', () {
      expect(copiedPath('Docs/lease.pdf', 'Photos'), 'Photos/lease.pdf');
      expect(copiedPath('lease.pdf', ''), 'lease.pdf');
      expect(copiedPath('Docs/lease.pdf', 'Docs'), 'Docs/lease.pdf');
    });
  });
}
