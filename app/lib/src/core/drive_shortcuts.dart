import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'vault_service.dart';

/// Every list action this app shares with Google Drive's keymap.
///
/// The bindings below are the single source of truth: the file list resolves
/// key events through [resolveDriveAction], and the shortcut sheet prints the
/// same table, so what the app does and what it documents cannot drift apart.
enum DriveAction {
  moveToFolder,
  cut,
  copy,
  paste,
  copyTitles,
  copyPaths,
  shareSelection,
  undo,
  redo,
  open,
  rename,
  delete,
  preview,
  toggleSelection,
  selectAll,
  clearSelection,
  rowDown,
  rowUp,
  extendDown,
  extendUp,
  focusDown,
  focusUp,
  rowFirst,
  rowLast,
  upOneFolder,
  goBack,
  goForward,
  refresh,
  focusSearch,
  newFolder,
  upload,
  createMenu,
  settings,
  shortcutList,
  focusList,
  properties,
  contextMenu,
}

/// `primary` is Ctrl on Windows/Linux/ChromeOS and ⌘ on macOS, as in Drive.
class DriveKeyBinding {
  const DriveKeyBinding(this.action, this.key, {this.primary = false, this.alt = false, this.shift = false});

  final DriveAction action;
  final LogicalKeyboardKey key;
  final bool primary;
  final bool alt;
  final bool shift;

  bool matches(LogicalKeyboardKey pressed, {required bool primary, required bool alt, required bool shift}) =>
      key == pressed && this.primary == primary && this.alt == alt && this.shift == shift;
}

const driveKeyBindings = <DriveKeyBinding>[
  DriveKeyBinding(DriveAction.moveToFolder, LogicalKeyboardKey.keyM, primary: true, alt: true),
  DriveKeyBinding(DriveAction.cut, LogicalKeyboardKey.keyX, primary: true),
  DriveKeyBinding(DriveAction.copy, LogicalKeyboardKey.keyC, primary: true),
  DriveKeyBinding(DriveAction.paste, LogicalKeyboardKey.keyV, primary: true),
  DriveKeyBinding(DriveAction.copyTitles, LogicalKeyboardKey.keyC, primary: true, shift: true),
  // Drive copies item URLs; the vault's equivalent identifier is the path.
  DriveKeyBinding(DriveAction.copyPaths, LogicalKeyboardKey.keyL, primary: true, alt: true),
  DriveKeyBinding(DriveAction.shareSelection, LogicalKeyboardKey.keyA, primary: true, alt: true),
  DriveKeyBinding(DriveAction.undo, LogicalKeyboardKey.keyZ, primary: true),
  DriveKeyBinding(DriveAction.redo, LogicalKeyboardKey.keyY, primary: true),
  // Drive's "open in a new tab" needs a browser tab per item; here it opens the
  // entry wherever the platform can, which is the same key with no modifier.
  DriveKeyBinding(DriveAction.open, LogicalKeyboardKey.enter),
  DriveKeyBinding(DriveAction.open, LogicalKeyboardKey.numpadEnter),
  DriveKeyBinding(DriveAction.open, LogicalKeyboardKey.enter, primary: true),
  DriveKeyBinding(DriveAction.rename, LogicalKeyboardKey.f2),
  DriveKeyBinding(DriveAction.delete, LogicalKeyboardKey.delete),
  DriveKeyBinding(DriveAction.delete, LogicalKeyboardKey.delete, shift: true),
  // Drive documents Shift+3 ("#") as a second delete key on US layouts.
  DriveKeyBinding(DriveAction.delete, LogicalKeyboardKey.numberSign, shift: true),
  DriveKeyBinding(DriveAction.preview, LogicalKeyboardKey.space),
  DriveKeyBinding(DriveAction.preview, LogicalKeyboardKey.keyP, primary: true, alt: true),
  DriveKeyBinding(DriveAction.toggleSelection, LogicalKeyboardKey.space, shift: true),
  DriveKeyBinding(DriveAction.selectAll, LogicalKeyboardKey.keyA, primary: true),
  DriveKeyBinding(DriveAction.clearSelection, LogicalKeyboardKey.escape),
  DriveKeyBinding(DriveAction.rowDown, LogicalKeyboardKey.arrowDown),
  DriveKeyBinding(DriveAction.rowUp, LogicalKeyboardKey.arrowUp),
  // A list has one axis: the horizontal arrows walk it too, as Drive's grid does.
  DriveKeyBinding(DriveAction.rowDown, LogicalKeyboardKey.arrowRight),
  DriveKeyBinding(DriveAction.rowUp, LogicalKeyboardKey.arrowLeft),
  DriveKeyBinding(DriveAction.extendDown, LogicalKeyboardKey.arrowDown, shift: true),
  DriveKeyBinding(DriveAction.extendUp, LogicalKeyboardKey.arrowUp, shift: true),
  DriveKeyBinding(DriveAction.extendDown, LogicalKeyboardKey.arrowRight, shift: true),
  DriveKeyBinding(DriveAction.extendUp, LogicalKeyboardKey.arrowLeft, shift: true),
  DriveKeyBinding(DriveAction.focusDown, LogicalKeyboardKey.arrowDown, primary: true),
  DriveKeyBinding(DriveAction.focusUp, LogicalKeyboardKey.arrowUp, primary: true),
  DriveKeyBinding(DriveAction.focusDown, LogicalKeyboardKey.arrowRight, primary: true),
  DriveKeyBinding(DriveAction.focusUp, LogicalKeyboardKey.arrowLeft, primary: true),
  DriveKeyBinding(DriveAction.rowFirst, LogicalKeyboardKey.home),
  DriveKeyBinding(DriveAction.rowLast, LogicalKeyboardKey.end),
  DriveKeyBinding(DriveAction.upOneFolder, LogicalKeyboardKey.arrowUp, alt: true),
  DriveKeyBinding(DriveAction.upOneFolder, LogicalKeyboardKey.backspace),
  DriveKeyBinding(DriveAction.goBack, LogicalKeyboardKey.arrowLeft, alt: true),
  DriveKeyBinding(DriveAction.goForward, LogicalKeyboardKey.arrowRight, alt: true),
  DriveKeyBinding(DriveAction.refresh, LogicalKeyboardKey.f5),
  DriveKeyBinding(DriveAction.focusSearch, LogicalKeyboardKey.keyF, primary: true),
  DriveKeyBinding(DriveAction.focusSearch, LogicalKeyboardKey.f3),
  DriveKeyBinding(DriveAction.focusSearch, LogicalKeyboardKey.slash),
  DriveKeyBinding(DriveAction.newFolder, LogicalKeyboardKey.keyN, primary: true, shift: true),
  DriveKeyBinding(DriveAction.createMenu, LogicalKeyboardKey.keyN, alt: true),
  DriveKeyBinding(DriveAction.settings, LogicalKeyboardKey.keyS, primary: true, shift: true),
  DriveKeyBinding(DriveAction.shortcutList, LogicalKeyboardKey.slash, primary: true),
  DriveKeyBinding(DriveAction.properties, LogicalKeyboardKey.enter, alt: true),
  DriveKeyBinding(DriveAction.properties, LogicalKeyboardKey.keyI, primary: true),
  DriveKeyBinding(DriveAction.goBack, LogicalKeyboardKey.bracketLeft, primary: true),
  DriveKeyBinding(DriveAction.goForward, LogicalKeyboardKey.bracketRight, primary: true),
  DriveKeyBinding(DriveAction.contextMenu, LogicalKeyboardKey.f10, shift: true),
  DriveKeyBinding(DriveAction.contextMenu, LogicalKeyboardKey.keyA, alt: true),
];

/// The action a key press stands for, or null when the key is not bound.
///
/// Modifiers must match exactly: Ctrl+Shift+V is Drive's "paste as shortcut",
/// which has no equivalent here, so it stays unbound instead of pasting.
DriveAction? resolveDriveAction({
  required LogicalKeyboardKey key,
  bool primary = false,
  bool alt = false,
  bool shift = false,
}) {
  for (final binding in driveKeyBindings) {
    if (binding.matches(key, primary: primary, alt: alt, shift: shift)) return binding.action;
  }
  return null;
}

String driveActionLabel(DriveAction action) => switch (action) {
  DriveAction.moveToFolder => 'Move to folder',
  DriveAction.cut => 'Cut',
  DriveAction.copy => 'Copy',
  DriveAction.paste => 'Paste',
  DriveAction.copyTitles => 'Copy item titles',
  DriveAction.copyPaths => 'Copy item paths',
  DriveAction.shareSelection => 'Share',
  DriveAction.undo => 'Undo',
  DriveAction.redo => 'Redo',
  DriveAction.open => 'Open',
  DriveAction.rename => 'Rename',
  DriveAction.delete => 'Delete',
  DriveAction.preview => 'Preview',
  DriveAction.toggleSelection => 'Select or deselect the current item',
  DriveAction.selectAll => 'Select all',
  DriveAction.clearSelection => 'Clear selection',
  DriveAction.rowDown => 'Next item',
  DriveAction.rowUp => 'Previous item',
  DriveAction.extendDown => 'Extend selection down',
  DriveAction.extendUp => 'Extend selection up',
  DriveAction.focusDown => 'Move focus down without selecting',
  DriveAction.focusUp => 'Move focus up without selecting',
  DriveAction.rowFirst => 'First item',
  DriveAction.rowLast => 'Last item',
  DriveAction.upOneFolder => 'Go up one folder',
  DriveAction.goBack => 'Back',
  DriveAction.goForward => 'Forward',
  DriveAction.refresh => 'Refresh',
  DriveAction.focusSearch => 'Search',
  DriveAction.newFolder => 'New folder',
  DriveAction.upload => 'Upload files',
  DriveAction.createMenu => 'New folder or upload',
  DriveAction.settings => 'Settings',
  DriveAction.shortcutList => 'Show the shortcut list',
  DriveAction.focusList => 'Focus the item list',
  DriveAction.properties => 'Properties',
  DriveAction.contextMenu => 'More actions',
};

String driveBindingLabel(DriveKeyBinding binding) {
  final parts = <String>[if (binding.primary) 'Ctrl/⌘', if (binding.alt) 'Alt', if (binding.shift) 'Shift'];
  final key = switch (binding.key) {
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
  };
  parts.add(key);
  return parts.join('+');
}

/// Drive's two-key shortcuts, e.g. Alt+C then F for a new folder.
enum ChordLeader { create, focus }

/// The second key of a chord, valid only for a moment after the leader.
class ChordSession {
  ChordSession({this.window = const Duration(seconds: 3)});

  final Duration window;
  ChordLeader? _leader;
  DateTime _armedAt = DateTime.fromMillisecondsSinceEpoch(0);

  ChordLeader? get leader => _leader;
  bool get isArmed => _leader != null;

  /// Arms the chord when [key] is its leader, so the caller can swallow the key.
  bool armFor(LogicalKeyboardKey key, {required bool alt, required DateTime now}) {
    if (!alt) return false;
    if (key == LogicalKeyboardKey.keyC) {
      _leader = ChordLeader.create;
      _armedAt = now;
      return true;
    }
    if (key == LogicalKeyboardKey.keyG) {
      _leader = ChordLeader.focus;
      _armedAt = now;
      return true;
    }
    return false;
  }

  /// The action the second key stands for, or null. Always disarms.
  DriveAction? resolve(LogicalKeyboardKey key, DateTime now) {
    final leader = _leader;
    if (leader == null) return null;
    final expired = now.difference(_armedAt) > window;
    _leader = null;
    if (expired) return null;
    if (leader == ChordLeader.focus) {
      return key == LogicalKeyboardKey.keyI ? DriveAction.focusList : null;
    }
    if (key == LogicalKeyboardKey.keyF) return DriveAction.newFolder;
    if (key == LogicalKeyboardKey.keyU || key == LogicalKeyboardKey.keyI) return DriveAction.upload;
    return null;
  }

  void reset() => _leader = null;
}

/// Letters typed in a row jump the selection to the first matching name, like
/// type-ahead in a file manager.
class TypeAheadBuffer {
  TypeAheadBuffer({this.window = const Duration(milliseconds: 700)});

  final Duration window;
  String _text = '';
  DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);

  String get text => _text;

  /// Adds a character and returns the prefix to match, or '' when the buffer
  /// restarted because too much time passed.
  String add(String character, DateTime now) {
    if (now.difference(_at) > window) _text = '';
    _text += character.toLowerCase();
    _at = now;
    return _text;
  }

  void reset() => _text = '';
}

/// Index of the first name starting with [prefix] after [after], wrapping once.
int? typeAheadMatch(List<String> names, String prefix, {int after = -1}) {
  if (prefix.isEmpty || names.isEmpty) return null;
  final needle = prefix.toLowerCase();
  for (var step = 1; step <= names.length; step++) {
    final index = (after + step) % names.length;
    if (names[index].toLowerCase().startsWith(needle)) return index;
  }
  return null;
}

/// What Ctrl+X or Ctrl+C put on the app's clipboard: vault entries, not bytes,
/// so nothing is read until the paste.
class DriveClipboard {
  const DriveClipboard({required this.entries, required this.isCut});

  final List<VaultEntry> entries;
  final bool isCut;

  bool get isEmpty => entries.isEmpty;
}

enum VaultOperationKind { move, copy }

/// Where an entry was, and where the operation put it.
class VaultOperation {
  const VaultOperation({required this.kind, required this.to, required this.entries});

  final VaultOperationKind kind;
  final String to;
  final List<VaultEntry> entries;
}

/// Drives Ctrl+Z and Ctrl+Y: the operations that can be reversed, newest last.
class UndoJournal {
  final _undo = <VaultOperation>[];
  final _redo = <VaultOperation>[];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void record(VaultOperation operation) {
    _undo.add(operation);
    _redo.clear();
  }

  /// The operation to reverse, moved onto the redo stack.
  VaultOperation? undo() {
    if (_undo.isEmpty) return null;
    final operation = _undo.removeLast();
    _redo.add(operation);
    return operation;
  }

  /// The operation to re-apply, moved back onto the undo stack.
  VaultOperation? redo() {
    if (_redo.isEmpty) return null;
    final operation = _redo.removeLast();
    _undo.add(operation);
    return operation;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}

/// Where a copy of [entryPath] lands in [folder].
String copiedPath(String entryPath, String folder) => joinVaultPath(folder, p.basename(entryPath));

/// Everything the keymap can ask the file list to do. Implemented by the tab
/// and, in the tests, by a recorder — the dispatch itself is what is unit-tested.
abstract class DriveActionSink {
  void moveToFolder();
  void cut();
  void copy();
  void paste();
  void copyTitles();
  void copyPaths();
  void shareSelection();
  void undo();
  void redo();
  void openCurrent();
  void renameCurrent();
  void deleteSelection();
  void previewCurrent();
  void toggleCurrent();
  void selectAll();
  void clearSelection();
  void moveRow(int delta, {required bool extend});
  void moveFocus(int delta);
  void selectEdge({required bool last, required bool extend});
  void upOneFolder();
  void goBack();
  void goForward();
  void refresh();
  void focusSearch();
  void newFolder();
  void upload();
  void openCreateMenu();
  void openSettings();
  void showShortcutList();
  void focusList();
  void showProperties();
  void showContextMenu();
}

/// Turns key presses into [DriveAction]s and forwards them to the sink.
///
/// Owns the chord state so a lone Alt+C followed by F works, and so an expired
/// chord never fires a stale action.
class DriveShortcutController {
  DriveShortcutController(this.sink, {ChordSession? chord}) : chord = chord ?? ChordSession();

  final DriveActionSink sink;
  final ChordSession chord;

  /// True when the key was consumed, so the caller stops looking at it.
  bool handleKey({
    required LogicalKeyboardKey key,
    bool primary = false,
    bool alt = false,
    bool shift = false,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    if (chord.isArmed) {
      final chained = chord.resolve(key, at);
      if (chained != null) {
        run(chained);
        return true;
      }
    }
    if (chord.armFor(key, alt: alt, now: at)) return true;
    final action = resolveDriveAction(key: key, primary: primary, alt: alt, shift: shift);
    if (action == null) return false;
    run(action);
    return true;
  }

  void run(DriveAction action) {
    switch (action) {
      case DriveAction.moveToFolder:
        sink.moveToFolder();
      case DriveAction.cut:
        sink.cut();
      case DriveAction.copy:
        sink.copy();
      case DriveAction.paste:
        sink.paste();
      case DriveAction.copyTitles:
        sink.copyTitles();
      case DriveAction.copyPaths:
        sink.copyPaths();
      case DriveAction.shareSelection:
        sink.shareSelection();
      case DriveAction.undo:
        sink.undo();
      case DriveAction.redo:
        sink.redo();
      case DriveAction.open:
        sink.openCurrent();
      case DriveAction.rename:
        sink.renameCurrent();
      case DriveAction.delete:
        sink.deleteSelection();
      case DriveAction.preview:
        sink.previewCurrent();
      case DriveAction.toggleSelection:
        sink.toggleCurrent();
      case DriveAction.selectAll:
        sink.selectAll();
      case DriveAction.clearSelection:
        sink.clearSelection();
      case DriveAction.rowDown:
        sink.moveRow(1, extend: false);
      case DriveAction.rowUp:
        sink.moveRow(-1, extend: false);
      case DriveAction.extendDown:
        sink.moveRow(1, extend: true);
      case DriveAction.extendUp:
        sink.moveRow(-1, extend: true);
      case DriveAction.focusDown:
        sink.moveFocus(1);
      case DriveAction.focusUp:
        sink.moveFocus(-1);
      case DriveAction.rowFirst:
        sink.selectEdge(last: false, extend: false);
      case DriveAction.rowLast:
        sink.selectEdge(last: true, extend: false);
      case DriveAction.upOneFolder:
        sink.upOneFolder();
      case DriveAction.goBack:
        sink.goBack();
      case DriveAction.goForward:
        sink.goForward();
      case DriveAction.refresh:
        sink.refresh();
      case DriveAction.focusSearch:
        sink.focusSearch();
      case DriveAction.newFolder:
        sink.newFolder();
      case DriveAction.upload:
        sink.upload();
      case DriveAction.createMenu:
        sink.openCreateMenu();
      case DriveAction.settings:
        sink.openSettings();
      case DriveAction.shortcutList:
        sink.showShortcutList();
      case DriveAction.focusList:
        sink.focusList();
      case DriveAction.properties:
        sink.showProperties();
      case DriveAction.contextMenu:
        sink.showContextMenu();
    }
  }
}
