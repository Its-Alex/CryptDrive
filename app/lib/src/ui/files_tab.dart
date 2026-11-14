import 'dart:async';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/drive_shortcuts.dart';
import '../core/drop_folder_plan.dart';
import '../core/perf_log.dart';
import '../core/vault_service.dart';
import '../state/providers.dart';
import '../state/transfers.dart';
import 'entry_widgets.dart';
import 'file_actions.dart';
import 'widgets.dart';

class FilesTab extends ConsumerStatefulWidget {
  const FilesTab({super.key, this.active = true});

  /// False while another tab covers the list, so the drop target stops listening.
  final bool active;

  @override
  ConsumerState<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends ConsumerState<FilesTab> implements DriveActionSink {
  String _directory = '';
  String _query = '';
  final _search = TextEditingController();
  Timer? _searchDebounce;

  /// Deleted optimistically: hidden until the folder listing no longer has them.
  final _hidden = <String>{};

  /// Selected entries of the current folder, in selection order.
  final _selection = <String, VaultEntry>{};
  String? _selectionAnchor;

  /// Rows picked by the last Shift-click or long-press drag, so the next range
  /// can shrink without dropping rows picked one by one.
  final _rangeSelection = <String>{};

  /// Each row's bounds, to map a dragged finger back to a row.
  final _rowKeys = <String, GlobalKey>{};
  String? _rowKeysScope;
  String? _dragRow;

  /// Row the arrow keys act on, which may sit inside the selection.
  String? _cursor;

  /// Last row clicked with a mouse, to detect the second click of a double click
  /// without a double-tap recognizer, which would delay every single click.
  String? _lastTapPath;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Set by the Select button, so selection can start without a long press.
  bool _selectionMode = false;

  /// Holds keyboard focus for the selection shortcuts (Escape, Ctrl+A, Delete).
  final _shortcutsFocus = FocusNode(debugLabel: 'files');
  final _searchFocus = FocusNode(debugLabel: 'search');
  List<VaultEntry> _visibleEntries = const [];

  /// Drive's cut/copy buffer: entries, not bytes, so a paste never decrypts twice.
  DriveClipboard? _clipboard;

  /// Reverses moves and copies with Ctrl+Z / Ctrl+Y.
  final _journal = UndoJournal();

  /// Folder history behind Alt+← and Alt+→.
  final _back = <String>[];
  final _forward = <String>[];

  final _typeAhead = TypeAheadBuffer();
  late final DriveShortcutController _shortcutController = DriveShortcutController(this);

  bool get _selecting => _selectionMode || _selection.isNotEmpty;
  bool _dragging = false;
  StreamSubscription<List<SharedMediaFile>>? _sharedFiles;

  VaultService get _vault => ref.read(environmentProvider).requireValue.vault;
  FileActions get _actions => FileActions(context, ref);

  @override
  void initState() {
    super.initState();
    if (_onPhone) {
      _sharedFiles = ReceiveSharingIntent.instance.getMediaStream().listen(_onShared);
      ReceiveSharingIntent.instance.getInitialMedia().then((files) {
        _onShared(files);
        ReceiveSharingIntent.instance.reset();
      });
    }
  }

  @override
  void didUpdateWidget(FilesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Coming back from another tab: the list must own the keyboard again, or the
    // shortcuts would go to whatever took focus (the nav rail, a dialog button).
    if (!oldWidget.active && widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _shortcutsFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _sharedFiles?.cancel();
    _searchDebounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _shortcutsFocus.dispose();
    super.dispose();
  }

  void _navigate(String directory) {
    if (directory == _directory) return;
    _back.add(_directory);
    _forward.clear();
    _open(directory);
  }

  void _open(String directory) {
    _search.clear();
    _selection.clear();
    _rangeSelection.clear();
    _selectionAnchor = null;
    _cursor = null;
    _selectionMode = false;
    setState(() {
      _directory = directory;
      _query = '';
    });
  }

  void _onSearchChanged(String text) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = text.trim());
    });
  }

  void _refresh() {
    if (_query.isNotEmpty) {
      ref.invalidate(searchProvider(_query));
    } else {
      ref.invalidate(folderProvider(_directory));
    }
  }

  Future<void> _reload() async {
    _refresh();
    if (_query.isNotEmpty) {
      await ref.read(searchProvider(_query).future).catchError((_) => <VaultEntry>[]);
    } else {
      await ref.read(folderProvider(_directory).future).catchError((_) => <VaultEntry>[]);
    }
  }

  Future<void> _onShared(List<SharedMediaFile> shared) async {
    final files = shared
        .where((item) => item.type != SharedMediaType.text && item.type != SharedMediaType.url)
        .toList();
    if (files.isEmpty || !mounted) return;
    final target = _directory.isEmpty ? 'the vault root' : _directory;
    final proceed = await confirm(
      context,
      title: 'Upload shared files',
      message: 'Encrypt and upload ${files.length} file(s) to $target?',
      confirmLabel: 'Upload',
    );
    if (!proceed || !mounted) return;
    await _actions.upload([for (final file in files) File(file.path)], _directory, deleteStaged: true);
  }

  Future<void> _pickAndUpload() async {
    final picked = await FilePicker.pickFiles(dialogTitle: 'Upload to vault');
    if (picked.isEmpty || !mounted) return;
    perfLog('[upload] picker window closed on ${picked.length} file(s): ${picked.map((file) => file.name).join(', ')}');
    await _uploadFiles([for (final file in picked) file.xFile]);
  }

  Future<void> _onDropped(DropDoneDetails details) async {
    if (mounted) setState(() => _dragging = false);
    final files = <DropItem>[];
    final folders = <DropItem>[];
    for (final item in details.files) {
      (await _isDroppedFolder(item) ? folders : files).add(item);
    }
    if (files.isEmpty && folders.isEmpty) return;
    final scoped = await _openSecurityScopes(details.files);
    try {
      if (files.isNotEmpty) await _uploadFiles(files);
      for (final folder in folders) {
        await _uploadFolder(folder);
      }
    } finally {
      for (final item in scoped) {
        await DesktopDrop.instance.stopAccessingSecurityScopedResource(bookmark: item.extraAppleBookmark!);
      }
    }
  }

  /// macOS and browsers report a directory as [DropItemDirectory]; Linux and
  /// Windows hand over a plain path that has to be probed.
  Future<bool> _isDroppedFolder(DropItem item) async {
    if (item is DropItemDirectory) return true;
    if (kIsWeb) return false;
    return FileSystemEntity.isDirectory(item.path);
  }

  /// A folder dropped from outside the sandbox is only readable while its
  /// security-scoped bookmark is open, files in it included.
  Future<List<DropItem>> _openSecurityScopes(List<DropItem> items) async {
    final opened = <DropItem>[];
    for (final item in items) {
      final bookmark = item.extraAppleBookmark;
      if (bookmark == null ||
          bookmark.isEmpty ||
          !await DesktopDrop.instance.startAccessingSecurityScopedResource(bookmark: bookmark)) {
        continue;
      }
      opened.add(item);
    }
    return opened;
  }

  Future<void> _uploadFolder(DropItem folder) async {
    if (kIsWeb) {
      final uploads = await planDroppedFolderMemory(folder as DropItemDirectory);
      if (uploads.isEmpty) {
        if (mounted) showMessage(context, 'Nothing to upload in ${folder.name}.');
        return;
      }
      if (mounted) await _actions.uploadFolderInMemory(uploads, _directory);
      return;
    }
    final plan = await planFolderUpload(Directory(folder.path), _directory);
    if (mounted) await _actions.uploadFolder(plan, _directory);
  }

  Future<void> _uploadFiles(List<XFile> files) async {
    if (kIsWeb) {
      if (mounted) await _actions.uploadPicked(files, _directory);
      return;
    }
    final stagingDir = await Directory.systemTemp.createTemp('cryptdrive-upload');
    try {
      final staged = <File>[];
      for (final file in files) {
        final localPath = file.path;
        if (localPath.isNotEmpty && await File(localPath).exists()) {
          staged.add(File(localPath));
        } else {
          final copy = File(p.join(stagingDir.path, file.name));
          await file.saveTo(copy.path);
          staged.add(copy);
        }
      }
      if (mounted) await _actions.upload(staged, _directory);
    } finally {
      await stagingDir.delete(recursive: true);
    }
  }

  Future<void> _newFolder() async {
    final name = await askText(context, title: 'New folder', label: 'Folder name', confirmLabel: 'Create');
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await _vault.createFolder(joinVaultPath(_directory, name));
    } catch (error) {
      if (mounted) showMessage(context, describeError(error));
    }
    _refresh();
  }

  Future<void> _showAddSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('uploadFiles'),
            leading: const Icon(Icons.upload_file),
            title: const Text('Upload files'),
            subtitle: const Text('Encrypted on this device before upload'),
            onTap: () => Navigator.of(context).pop('upload'),
          ),
          ListTile(
            key: const Key('newFolder'),
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('New folder'),
            onTap: () => Navigator.of(context).pop('folder'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (choice == 'upload') await _pickAndUpload();
    if (choice == 'folder') await _newFolder();
  }

  /// Touch opens a row on tap and selects it on long press; a mouse selects a
  /// row on click and opens it on double click, as Drive does.
  Future<void> _onTap(VaultEntry entry) async {
    _shortcutsFocus.requestFocus();
    if (_onPhone) {
      if (_selecting) return _toggleSelection(entry);
      return _openEntry(entry);
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed) {
      _lastTapPath = null;
      return _extendSelection(entry);
    }
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      _lastTapPath = null;
      return _toggleSelection(entry);
    }
    final now = DateTime.now();
    final isDoubleClick = _lastTapPath == entry.path && now.difference(_lastTapAt) < kDoubleTapTimeout;
    _lastTapPath = entry.path;
    _lastTapAt = now;
    if (isDoubleClick) {
      _lastTapPath = null;
      return _openEntry(entry);
    }
    if (_selection.length == 1 && _selection.containsKey(entry.path)) return;
    _selectOnly(entry);
  }

  void _selectOnly(VaultEntry entry) {
    setState(() {
      _selection
        ..clear()
        ..[entry.path] = entry;
      _rangeSelection.clear();
      _selectionAnchor = entry.path;
      _cursor = entry.path;
    });
  }

  Future<void> _openEntry(VaultEntry entry) async {
    if (entry.isDir) return _navigate(entry.path);
    await _actions.run(entry, EntryAction.open);
  }

  void _toggleSelection(VaultEntry entry) {
    _shortcutsFocus.requestFocus();
    setState(() {
      _rangeSelection.remove(entry.path);
      if (_selection.remove(entry.path) == null) _selection[entry.path] = entry;
      _selectionAnchor = entry.path;
      _cursor = entry.path;
    });
  }

  /// A row's bounds, so a drag or a keyboard move can tell which row it means.
  Widget _selectableRow(VaultEntry entry, Widget row) {
    return GestureDetector(
      key: _rowKeys.putIfAbsent(entry.path, () => GlobalKey(debugLabel: 'row:${entry.path}')),
      onLongPressStart: (_) => _startDragSelection(entry),
      onLongPressMoveUpdate: (details) => _dragSelectionTo(details.globalPosition),
      onLongPressEnd: (_) => _dragRow = null,
      onSecondaryTap: () => _onSecondaryTap(entry),
      child: row,
    );
  }

  /// Right click selects the row when needed, then opens its menu, as Drive does.
  void _onSecondaryTap(VaultEntry entry) {
    _shortcutsFocus.requestFocus();
    if (!_selection.containsKey(entry.path)) _selectOnly(entry);
    unawaited(_onMenu(entry));
  }

  /// A click on empty space clears the selection, as in Drive.
  void _onEmptyArea() {
    if (_onPhone || !_selecting) return;
    _clearSelection();
  }

  /// Long press selects the row and anchors there; dragging then extends the
  /// range, like a file manager, without having to lift the finger.
  void _startDragSelection(VaultEntry entry) {
    _shortcutsFocus.requestFocus();
    _dragRow = entry.path;
    setState(() {
      _selection[entry.path] = entry;
      _selectionAnchor = entry.path;
    });
  }

  void _dragSelectionTo(Offset globalPosition) {
    final path = _pathAt(globalPosition);
    if (path == null || path == _dragRow) return;
    _dragRow = path;
    _extendSelection(_visibleEntries.firstWhere((entry) => entry.path == path));
  }

  String? _pathAt(Offset globalPosition) {
    for (final entry in _visibleEntries) {
      final box = _rowKeys[entry.path]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      if ((box.localToGlobal(Offset.zero) & box.size).contains(globalPosition)) return entry.path;
    }
    return null;
  }

  /// Every bound key goes through [DriveShortcutController], so the shipped
  /// behaviour is exactly the table the unit tests cover. Letters that no binding
  /// claims feed the type-ahead buffer, as in a file manager.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final primary = keyboard.isControlPressed || keyboard.isMetaPressed;
    final alt = keyboard.isAltPressed;
    final shift = keyboard.isShiftPressed;
    if (_shortcutController.handleKey(key: event.logicalKey, primary: primary, alt: alt, shift: shift)) {
      return KeyEventResult.handled;
    }
    return _typeAheadKey(event, primary: primary, alt: alt) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _typeAheadKey(KeyEvent event, {required bool primary, required bool alt}) {
    final character = event.character;
    if (character == null || character.isEmpty || primary || alt) return false;
    if (!RegExp(r'^[\w .\-]$').hasMatch(character)) return false;
    final prefix = _typeAhead.add(character, DateTime.now());
    final index = typeAheadMatch([for (final entry in _visibleEntries) entry.name], prefix, after: _cursorIndex);
    if (index != null) {
      final entry = _visibleEntries[index];
      _selectOnly(entry);
      _scrollToRow(entry.path);
    }
    return true;
  }

  int get _cursorIndex {
    final path = _cursor ?? _selectionAnchor;
    if (path == null) return -1;
    return _visibleEntries.indexWhere((entry) => entry.path == path);
  }

  void _moveCursor(int delta, {required bool extend}) {
    final current = _cursorIndex;
    if (current == -1) return _moveCursorTo(delta > 0 ? 0 : _visibleEntries.length - 1, extend: extend);
    _moveCursorTo(current + delta, extend: extend);
  }

  void _moveCursorTo(int index, {required bool extend}) {
    if (index < 0 || index >= _visibleEntries.length) return;
    final entry = _visibleEntries[index];
    if (extend) {
      setState(() => _cursor = entry.path);
      _extendSelection(entry);
    } else {
      _selectOnly(entry);
    }
    _scrollToRow(entry.path);
  }

  void _moveFocus(int delta) {
    if (_visibleEntries.isEmpty) return;
    final current = _cursorIndex;
    final index = current == -1 ? (delta > 0 ? 0 : _visibleEntries.length - 1) : current + delta;
    if (index < 0 || index >= _visibleEntries.length) return;
    setState(() => _cursor = _visibleEntries[index].path);
    _scrollToRow(_visibleEntries[index].path);
  }

  void _openCursor() {
    final path = _cursor ?? _selectionAnchor;
    for (final entry in _visibleEntries) {
      if (entry.path != path) continue;
      _openEntry(entry);
      return;
    }
  }

  void _scrollToRow(String path) {
    final context = _rowKeys[path]?.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 120));
  }

  /// Shift-click or drag: selects from the anchor to [entry], or just [entry]
  /// when nothing was picked yet, so a range works on a fresh list.
  void _extendSelection(VaultEntry entry) {
    final anchor = _selectionAnchor;
    final paths = _visibleEntries.map((e) => e.path).toList();
    final from = anchor == null ? -1 : paths.indexOf(anchor);
    final to = paths.indexOf(entry.path);
    if (from == -1 || to == -1) return _toggleSelection(entry);
    final start = from < to ? from : to;
    final range = _visibleEntries.sublist(start, (from < to ? to : from) + 1);
    final rangePaths = {for (final selected in range) selected.path};
    setState(() {
      _selection.removeWhere((path, _) => _rangeSelection.contains(path) && !rangePaths.contains(path));
      for (final selected in range) {
        _selection[selected.path] = selected;
      }
      _rangeSelection
        ..clear()
        ..addAll(rangePaths);
    });
  }

  void _selectAll() => setState(() {
    _rangeSelection.clear();
    for (final entry in _visibleEntries) {
      _selection[entry.path] = entry;
    }
  });

  Future<void> _renameSelected() async {
    if (_selection.length != 1) {
      showMessage(context, 'Rename works on one item at a time.');
      return;
    }
    await _actions.run(_selection.values.single, EntryAction.rename);
  }

  // --- DriveActionSink: what the keymap can ask the list to do --------------

  @override
  void moveToFolder() {
    if (_selection.isEmpty) return;
    unawaited(_moveSelected());
  }

  @override
  void cut() => _rememberClipboard(isCut: true);

  @override
  void copy() => _rememberClipboard(isCut: false);

  void _rememberClipboard({required bool isCut}) {
    final entries = _selectedEntries;
    if (entries.isEmpty) return;
    setState(() => _clipboard = DriveClipboard(entries: entries, isCut: isCut));
    showMessage(context, '${isCut ? 'Cut' : 'Copied'} ${entries.length} ${entries.length == 1 ? 'item' : 'items'}');
  }

  @override
  void paste() => unawaited(_paste());

  Future<void> _paste() async {
    final clipboard = _clipboard;
    if (clipboard == null || clipboard.isEmpty) {
      showMessage(context, 'Nothing to paste: cut or copy something first.');
      return;
    }
    final folder = _directory;
    final entries = clipboard.isCut
        ? clipboard.entries.where((entry) => parentVaultPath(entry.path) != folder).toList()
        : clipboard.entries;
    if (entries.isEmpty) return;
    if (clipboard.isCut) setState(() => _hidden.addAll(entries.map((entry) => entry.path)));
    final affected = clipboard.isCut
        ? await _actions.moveMany(entries, folder)
        : await _actions.copyMany(entries, folder);
    if (!mounted) return;
    setState(() {
      if (clipboard.isCut) _hidden.removeAll(entries.map((entry) => entry.path));
    });
    if (affected.isEmpty) return;
    if (clipboard.isCut) setState(() => _clipboard = null);
    _journal.record(
      VaultOperation(
        kind: clipboard.isCut ? VaultOperationKind.move : VaultOperationKind.copy,
        to: folder,
        entries: entries,
      ),
    );
    await _reload();
    if (!mounted) return;
    showMessage(
      context,
      '${clipboard.isCut ? 'Moved' : 'Copied'} ${affected.length} to ${folder.isEmpty ? 'Vault' : folder}',
    );
  }

  @override
  void copyTitles() => unawaited(_copyTitles());

  Future<void> _copyTitles() async {
    final titles = _selectedEntries.map((entry) => entry.name).join('\n');
    if (titles.isEmpty) return;
    if (!await _writeClipboard(titles)) return;
    if (!mounted) return;
    showMessage(context, 'Copied ${_selection.length} ${_selection.length == 1 ? 'title' : 'titles'}');
  }

  /// Returns false when the platform has no clipboard to write to.
  Future<bool> _writeClipboard(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (error) {
      if (mounted) showMessage(context, 'Could not copy to the clipboard: ${describeError(error)}');
      return false;
    }
  }

  @override
  void copyPaths() => unawaited(_copyPaths());

  Future<void> _copyPaths() async {
    final paths = _selectedEntries.map((entry) => entry.path).join('\n');
    if (paths.isEmpty) return;
    if (!await _writeClipboard(paths)) return;
    if (!mounted) return;
    showMessage(context, 'Copied ${_selection.length} ${_selection.length == 1 ? 'path' : 'paths'}');
  }

  @override
  void shareSelection() => unawaited(_shareSelection());

  Future<void> _shareSelection() async {
    final files = _selectedEntries.where((entry) => !entry.isDir).toList();
    if (files.isEmpty) {
      showMessage(context, 'Share works on files.');
      return;
    }
    if (!canShareFiles) {
      showMessage(context, 'This platform has no share sheet: use Save decrypted copies instead.');
      return;
    }
    await _actions.shareMany(files);
  }

  @override
  void focusList() => _shortcutsFocus.requestFocus();

  @override
  void undo() => unawaited(_applyJournal(undo: true));

  @override
  void redo() => unawaited(_applyJournal(undo: false));

  Future<void> _applyJournal({required bool undo}) async {
    final operation = undo ? _journal.undo() : _journal.redo();
    if (operation == null) {
      showMessage(context, undo ? 'Nothing to undo.' : 'Nothing to redo.');
      return;
    }
    var changed = 0;
    for (final entry in operation.entries) {
      final destination = copiedPath(entry.path, operation.to);
      try {
        switch (operation.kind) {
          case VaultOperationKind.move:
            final from = undo ? destination : entry.path;
            final to = undo ? entry.path : destination;
            await _vault.move(_pathEntry(from, entry.isDir), to);
          case VaultOperationKind.copy:
            if (undo) {
              await _vault.delete(_pathEntry(destination, entry.isDir));
            } else {
              await _vault.copy(entry, destination);
            }
        }
        changed++;
      } catch (error) {
        if (mounted) showMessage(context, describeError(error));
      }
    }
    if (!mounted) return;
    setState(() {
      _selection.clear();
      _rangeSelection.clear();
      _selectionAnchor = null;
      _cursor = null;
    });
    await _reload();
    ref.invalidate(folderProvider(operation.to));
    if (changed > 0 && mounted) showMessage(context, undo ? 'Undone.' : 'Redone.');
  }

  VaultEntry _pathEntry(String path, bool isDir) =>
      VaultEntry(path: path, name: p.basename(path), isDir: isDir, size: 0, modTime: null);

  @override
  void openCurrent() => _openCursor();

  @override
  void renameCurrent() => unawaited(_renameSelected());

  @override
  void deleteSelection() {
    if (_selection.isEmpty) return;
    unawaited(_deleteSelected());
  }

  @override
  void previewCurrent() {
    final entries = _selectedEntries;
    if (entries.length != 1) {
      showMessage(context, 'Preview works on one item at a time.');
      return;
    }
    final entry = entries.single;
    if (entry.isDir) {
      showMessage(context, 'Folders have no preview.');
      return;
    }
    if (!canPreview(entry)) {
      showMessage(context, 'No preview for this file type.');
      return;
    }
    unawaited(_actions.run(entry, EntryAction.preview));
  }

  @override
  void toggleCurrent() {
    final index = _cursorIndex;
    if (index == -1) return;
    _toggleSelection(_visibleEntries[index]);
  }

  @override
  void selectAll() => _selectAll();

  @override
  void clearSelection() => _clearSelection();

  @override
  void moveRow(int delta, {required bool extend}) => _moveCursor(delta, extend: extend);

  @override
  void moveFocus(int delta) => _moveFocus(delta);

  @override
  void selectEdge({required bool last, required bool extend}) {
    if (_visibleEntries.isEmpty) return;
    _moveCursorTo(last ? _visibleEntries.length - 1 : 0, extend: extend);
  }

  @override
  void upOneFolder() {
    if (_query.isNotEmpty) return _open(_directory);
    _navigate(parentVaultPath(_directory));
  }

  @override
  void goBack() {
    if (_back.isEmpty) return;
    _forward.add(_directory);
    _open(_back.removeLast());
  }

  @override
  void goForward() {
    if (_forward.isEmpty) return;
    _back.add(_directory);
    _open(_forward.removeLast());
  }

  @override
  void refresh() => _refresh();

  @override
  void focusSearch() {
    if (_selecting) _clearSelection();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void newFolder() => unawaited(_newFolder());

  @override
  void upload() => unawaited(_pickAndUpload());

  @override
  void openCreateMenu() => unawaited(_showAddSheet());

  @override
  void openSettings() => ref.read(homeTabProvider.notifier).select(2);

  @override
  void showShortcutList() => _showShortcutList();

  @override
  void showProperties() => _showProperties();

  void _showShortcutList() {
    final grouped = <DriveAction, List<String>>{};
    for (final binding in driveKeyBindings) {
      (grouped[binding.action] ??= []).add(driveBindingLabel(binding));
    }
    final actions = grouped.keys.toList()..sort((a, b) => driveActionLabel(a).compareTo(driveActionLabel(b)));
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keyboard shortcuts'),
        content: SizedBox(
          width: (MediaQuery.sizeOf(context).width - 140).clamp(220.0, 560.0).toDouble(),
          height: (MediaQuery.sizeOf(context).height - 260).clamp(160.0, 520.0).toDouble(),
          child: ListView(
            children: [
              for (final action in actions)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 220, child: Text(driveActionLabel(action))),
                      Expanded(
                        child: Text(
                          grouped[action]!.join('  or  '),
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 220, child: Text('New folder / upload (chord)')),
                    Expanded(child: Text('Alt+C then F, or Alt+C then U or I')),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 220, child: Text('Focus the list (chord)')),
                    Expanded(child: Text('Alt+G then I')),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 220, child: Text('Jump to a name')),
                    Expanded(child: Text('Type its first letters')),
                  ],
                ),
              ),
              const Divider(height: 24),
              Text(
                'From Drive, with nothing to act on here: star, create shortcut, paste as shortcut, '
                'print, grid/list toggle, row density, details pane, sort menu, the folders/page/details '
                'focus chords (Alt+G then I focuses this list), and the download/upload status panel.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('closeShortcuts'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showProperties() {
    final entries = _selectedEntries;
    if (entries.length != 1) {
      showMessage(context, 'Properties need one selected item.');
      return;
    }
    final entry = entries.single;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Properties'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _property('Name', entry.name),
            _property('Type', entry.isDir ? 'Folder' : (entry.mimeType ?? 'File')),
            if (!entry.isDir) _property('Size', formatBytes(entry.size)),
            _property('Modified', entry.modTime == null ? 'Unknown' : formatDate(entry.modTime!)),
            _property('In', parentVaultPath(entry.path).isEmpty ? 'Vault' : parentVaultPath(entry.path)),
            _property('Path', entry.path),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }

  Widget _property(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );

  @override
  void showContextMenu() {
    final entries = _selectedEntries;
    if (entries.length != 1) {
      showMessage(context, 'More actions work on one item at a time.');
      return;
    }
    unawaited(_onMenu(entries.single));
  }

  void _clearSelection() => setState(() {
    _selection.clear();
    _rangeSelection.clear();
    _selectionAnchor = null;
    _selectionMode = false;
  });

  void _startSelecting() {
    _shortcutsFocus.requestFocus();
    setState(() => _selectionMode = true);
  }

  List<VaultEntry> get _selectedEntries => _selection.values.toList();

  bool get _onPhone =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  bool get _selectionHasOnlyFiles => _selection.values.every((entry) => !entry.isDir);

  Future<void> _moveSelected() async {
    final entries = _selectedEntries;
    final destination = await askText(
      context,
      title: 'Move ${entries.length} ${entries.length == 1 ? 'item' : 'items'}',
      label: 'Destination folder (empty = vault root)',
      initialValue: _directory,
      confirmLabel: 'Move',
    );
    if (destination == null || !mounted) return;
    final folder = destination.replaceAll(RegExp(r'^/+|/+$'), '');
    if (entries.every((entry) => parentVaultPath(entry.path) == folder)) return;
    setState(() => _hidden.addAll(entries.map((e) => e.path)));
    _clearSelection();
    final moved = await _actions.moveMany(entries, folder);
    if (!mounted) return;
    await _reload();
    if (mounted) setState(() => _hidden.removeAll(entries.map((e) => e.path)));
    if (mounted && moved.isNotEmpty) {
      showMessage(context, 'Moved ${moved.length} to ${folder.isEmpty ? 'Vault' : folder}');
    }
  }

  Future<void> _deleteSelected() async {
    final entries = _selectedEntries;
    final folders = entries.where((e) => e.isDir).length;
    final proceed = await confirm(
      context,
      title: 'Delete ${entries.length} ${entries.length == 1 ? 'item' : 'items'}?',
      message: folders == 0
          ? 'The selected files will be deleted.'
          : 'The selected files and folders, with everything in them, will be deleted.',
      confirmLabel: 'Delete',
    );
    if (!proceed || !mounted) return;
    setState(() => _hidden.addAll(entries.map((e) => e.path)));
    _clearSelection();
    await _actions.deleteMany(entries);
    if (!mounted) return;
    await _reload();
    if (mounted) setState(() => _hidden.removeAll(entries.map((e) => e.path)));
  }

  Future<void> _saveSelected() async {
    final files = _selectedEntries;
    _clearSelection();
    await _actions.saveCopies(files);
  }

  Future<void> _shareSelected() async {
    final files = _selectedEntries;
    _clearSelection();
    await _actions.shareMany(files);
  }

  Future<void> _onMenu(VaultEntry entry) async {
    final action = await showEntryActions(context, entry, _vault);
    if (action == null || !mounted) return;
    if (action == EntryAction.delete) {
      if (!await confirmDelete(context, entry)) return;
      return _deleteOptimistically(entry);
    }
    await _actions.run(entry, action);
  }

  Future<void> _deleteOptimistically(VaultEntry entry) async {
    setState(() => _hidden.add(entry.path));
    final deleted = await _actions.delete(entry);
    if (!mounted) return;
    if (deleted) await _reload();
    if (mounted) setState(() => _hidden.remove(entry.path));
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.isNotEmpty;
    // The folder list and the search results cross-fade for a frame, so two lists
    // can hold the same rows at once and need their own row keys.
    final scope = searching ? 'search:$_query' : 'dir:$_directory';
    if (scope != _rowKeysScope) {
      _rowKeysScope = scope;
      _rowKeys.clear();
    }
    return PopScope(
      canPop: _directory.isEmpty && !searching && !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) return _clearSelection();
        if (searching) return _open(_directory);
        _navigate(parentVaultPath(_directory));
      },
      child: DropTarget(
        enable: widget.active && (ModalRoute.of(context)?.isCurrent ?? true),
        onDragEntered: (_) {
          if (mounted) setState(() => _dragging = true);
        },
        onDragExited: (_) {
          if (mounted) setState(() => _dragging = false);
        },
        onDragDone: _onDropped,
        child: Stack(
          children: [
            Focus(
              focusNode: _shortcutsFocus,
              autofocus: true,
              onKeyEvent: _onKey,
              child: Scaffold(
                body: SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: _selecting ? _selectionBar() : _searchHeader(),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        child: searching
                            ? const SizedBox(width: double.infinity)
                            : _Breadcrumbs(directory: _directory, onOpen: _navigate),
                      ),
                      _transferStrip(),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          transitionBuilder: (child, animation) => FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(animation),
                              child: child,
                            ),
                          ),
                          child: KeyedSubtree(
                            key: ValueKey(searching ? 'search:$_query' : 'dir:$_directory'),
                            child: searching ? _searchResults() : _folderContents(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                floatingActionButton: _selecting
                    ? null
                    : FloatingActionButton(
                        key: const Key('addButton'),
                        tooltip: 'Add',
                        onPressed: _showAddSheet,
                        child: const Icon(Icons.add),
                      ),
              ),
            ),
            if (_dragging) Positioned.fill(child: _DropOverlay(directory: _directory)),
          ],
        ),
      ),
    );
  }

  Widget _searchHeader() {
    return Padding(
      key: const ValueKey('searchHeader'),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: SearchBar(
              key: const Key('searchField'),
              focusNode: _searchFocus,
              controller: _search,
              hintText: 'Search in vault',
              leading: const Icon(Icons.search),
              trailing: [
                if (_search.text.isNotEmpty)
                  IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: () => _open(_directory)),
              ],
              onChanged: (text) {
                setState(() {});
                _onSearchChanged(text);
              },
            ),
          ),
          // A mouse starts a selection with a click; only touch needs this.
          if (_onPhone)
            IconButton(
              key: const Key('startSelecting'),
              tooltip: 'Select',
              icon: const Icon(Icons.checklist),
              onPressed: _startSelecting,
            ),
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
    );
  }

  Widget _selectionBar() {
    final count = _selection.length;
    final hasSelection = count > 0;
    final filesOnly = _selectionHasOnlyFiles;
    return Padding(
      key: const ValueKey('selectionBar'),
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            IconButton(
              key: const Key('clearSelection'),
              tooltip: 'Clear selection',
              icon: const Icon(Icons.close),
              onPressed: _clearSelection,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '$count selected',
                key: const Key('selectionCount'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(tooltip: 'Select all', icon: const Icon(Icons.select_all), onPressed: _selectAll),
            // Phones save through the share sheet; there is no folder to pick there.
            if (filesOnly && hasSelection && !_onPhone)
              IconButton(
                key: const Key('saveSelected'),
                tooltip: kIsWeb ? 'Download' : 'Save decrypted copies',
                icon: const Icon(Icons.download_outlined),
                onPressed: _saveSelected,
              ),
            if (filesOnly && hasSelection && canShareFiles)
              IconButton(
                key: const Key('shareSelected'),
                tooltip: 'Share',
                icon: const Icon(Icons.share_outlined),
                onPressed: _shareSelected,
              ),
            IconButton(
              key: const Key('moveSelected'),
              tooltip: 'Move',
              icon: const Icon(Icons.drive_file_move_outline),
              onPressed: hasSelection ? _moveSelected : null,
            ),
            IconButton(
              key: const Key('deleteSelected'),
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: hasSelection ? _deleteSelected : null,
            ),
          ],
        ),
      ),
    );
  }

  /// Running transfers that have no row of their own on screen: the inline row only covers
  /// the folder being looked at, and drawing both would show two bars for one upload.
  Widget _transferStrip() {
    final directory = _directory;
    final active = ref.watch(transfersProvider).values.where((t) => t.directory != directory).toList();
    if (active.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      key: const Key('transferStrip'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final transfer in active)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      transfer.kind == TransferKind.upload ? Icons.cloud_upload_outlined : Icons.lock_open_outlined,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        transfer.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (transfer.fraction != null)
                      Text('${(transfer.fraction! * 100).round()}%', style: theme.textTheme.bodySmall),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: transfer.fraction, minHeight: 3),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _folderContents() {
    final directory = _directory;
    final listing = ref.watch(folderProvider(directory));
    final transfers = ref.watch(transfersProvider);
    return listing.when(
      loading: () => const SkeletonList(),
      error: (error, _) => ErrorView(error: error, onRetry: _refresh),
      data: (entries) {
        final listed = {for (final entry in entries) entry.path};
        final pendingUploads = transfers.values
            .where((t) => t.kind == TransferKind.upload && t.directory == directory && !listed.contains(t.path))
            .toList();
        final visible = entries.where((entry) => !_hidden.contains(entry.path)).toList();
        _visibleEntries = visible;
        if (visible.isEmpty && pendingUploads.isEmpty) return const _EmptyFolder();
        return RefreshIndicator(
          onRefresh: () => ref.refresh(folderProvider(directory).future),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            excludeFromSemantics: true,
            onTap: _onEmptyArea,
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: pendingUploads.length + visible.length,
              itemBuilder: (context, index) {
                if (index < pendingUploads.length) {
                  final upload = pendingUploads[index];
                  return EntryRow(
                    key: Key('pending:${upload.path}'),
                    entry: VaultEntry(path: upload.path, name: upload.name, isDir: false, size: -1, modTime: null),
                    vault: _vault,
                    transfer: upload,
                    onTap: null,
                    onMenu: null,
                  );
                }
                final entry = visible[index - pendingUploads.length];
                return Dismissible(
                  key: ValueKey('dismiss:${entry.path}'),
                  // Touch selects with a long press, so a swipe would fight it; a mouse
                  // starts a selection on pointer down, which must not kill its own swipe.
                  direction: _onPhone && _selecting ? DismissDirection.none : DismissDirection.endToStart,
                  background: const _DeleteBackground(),
                  confirmDismiss: (_) => confirmDelete(context, entry),
                  onDismissed: (_) => _deleteOptimistically(entry),
                  child: _selectableRow(
                    entry,
                    EntryRow(
                      key: Key('entry:${entry.path}'),
                      entry: entry,
                      vault: _vault,
                      transfer: transfers[entry.path],
                      onTap: () => _onTap(entry),
                      onMenu: () => _onMenu(entry),
                      onIconTap: () => _toggleSelection(entry),
                      selected: _selecting ? _selection.containsKey(entry.path) : null,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _searchResults() {
    final results = ref.watch(searchProvider(_query));
    final transfers = ref.watch(transfersProvider);
    return results.when(
      loading: () => const SkeletonList(),
      error: (error, _) => ErrorView(error: error, onRetry: _refresh),
      data: (entries) {
        final visible = entries.where((entry) => !_hidden.contains(entry.path)).toList();
        _visibleEntries = visible;
        if (entries.isEmpty) {
          return _Message(
            icon: Icons.search_off,
            title: 'No results',
            detail: 'Nothing in the vault matches "$_query".',
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          excludeFromSemantics: true,
          onTap: _onEmptyArea,
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final entry = visible[index];
              final parent = parentVaultPath(entry.path);
              return _selectableRow(
                entry,
                EntryRow(
                  key: Key('result:${entry.path}'),
                  entry: entry,
                  vault: _vault,
                  transfer: transfers[entry.path],
                  subtitleOverride: 'in ${parent.isEmpty ? 'Vault' : parent} · ${describeEntry(entry)}',
                  onTap: () => _onTap(entry),
                  onMenu: () => _onMenu(entry),
                  onIconTap: () => _toggleSelection(entry),
                  selected: _selecting ? _selection.containsKey(entry.path) : null,
                  focused: _cursor == entry.path,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay({required this.directory});

  final String directory;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: ColoredBox(
        key: const Key('dropOverlay'),
        color: scheme.scrim.withValues(alpha: 0.55),
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.primary, width: 2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.file_download_outlined, size: 44, color: scheme.primary),
                const SizedBox(height: 12),
                Text('Drop to upload', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  'Files and folders are encrypted and added to ${directory.isEmpty ? 'the vault root' : directory}.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.directory, required this.onOpen});

  final String directory;
  final void Function(String directory) onOpen;

  @override
  Widget build(BuildContext context) {
    final segments = directory.isEmpty ? <String>[] : directory.split('/');
    final scheme = Theme.of(context).colorScheme;
    Widget crumb(String label, String path, {required bool current}) => TextButton(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        foregroundColor: scheme.primary,
        disabledForegroundColor: scheme.onSurface,
        textStyle: TextStyle(fontWeight: current ? FontWeight.w600 : FontWeight.w500),
      ),
      onPressed: current ? null : () => onOpen(path),
      child: Text(label),
    );
    return SizedBox(
      height: 44,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth - 16),
            child: Row(
              children: [
                crumb('Vault', '', current: segments.isEmpty),
                for (final (index, segment) in segments.indexed) ...[
                  Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
                  crumb(segment, segments.sublist(0, index + 1).join('/'), current: index == segments.length - 1),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.errorContainer,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Delete',
            style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Icon(Icons.delete_outline, color: scheme.onErrorContainer),
        ],
      ),
    );
  }
}

class _EmptyFolder extends StatelessWidget {
  const _EmptyFolder();

  @override
  Widget build(BuildContext context) => const _Message(
    icon: Icons.cloud_upload_outlined,
    title: 'This folder is empty.',
    detail: 'Tap + to upload files or create a folder.\nEverything is encrypted before it leaves this device.',
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: scheme.primaryContainer.withValues(alpha: 0.5), shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: scheme.primary),
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
