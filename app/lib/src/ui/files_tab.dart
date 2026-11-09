import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/vault_service.dart';
import '../state/providers.dart';
import '../state/transfers.dart';
import 'entry_widgets.dart';
import 'file_actions.dart';
import 'widgets.dart';

class FilesTab extends ConsumerStatefulWidget {
  const FilesTab({super.key});

  @override
  ConsumerState<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends ConsumerState<FilesTab> {
  String _directory = '';
  String _query = '';
  final _search = TextEditingController();
  Timer? _searchDebounce;

  /// Deleted optimistically: hidden until the folder listing no longer has them.
  final _hidden = <String>{};

  /// Selected entries of the current folder, in selection order.
  final _selection = <String, VaultEntry>{};
  String? _selectionAnchor;

  /// Holds keyboard focus for the selection shortcuts (Escape, Ctrl+A, Delete).
  final _shortcutsFocus = FocusNode(debugLabel: 'files');
  List<VaultEntry> _visibleEntries = const [];

  bool get _selecting => _selection.isNotEmpty;
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
  void dispose() {
    _sharedFiles?.cancel();
    _searchDebounce?.cancel();
    _search.dispose();
    _shortcutsFocus.dispose();
    super.dispose();
  }

  void _open(String directory) {
    _search.clear();
    _selection.clear();
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
    if (kIsWeb) {
      final files = [for (final file in picked) (name: file.name, bytes: await file.xFile.readAsBytes())];
      if (mounted) await _actions.uploadPicked(files, _directory);
      return;
    }
    final stagingDir = await Directory.systemTemp.createTemp('cryptdrive-upload');
    try {
      final staged = <File>[];
      for (final file in picked) {
        final localPath = file.path;
        if (localPath != null && await File(localPath).exists()) {
          staged.add(File(localPath));
        } else {
          final copy = File(p.join(stagingDir.path, file.name));
          await file.xFile.saveTo(copy.path);
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

  Future<void> _onTap(VaultEntry entry) async {
    _shortcutsFocus.requestFocus();
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed && _selectionAnchor != null) return _selectRange(entry);
    if (keyboard.isControlPressed || keyboard.isMetaPressed || _selecting) return _toggleSelection(entry);
    if (entry.isDir) return _open(entry.path);
    await _actions.run(entry, EntryAction.open);
  }

  void _toggleSelection(VaultEntry entry) {
    _shortcutsFocus.requestFocus();
    setState(() {
      if (_selection.remove(entry.path) == null) _selection[entry.path] = entry;
      _selectionAnchor = entry.path;
    });
  }

  void _selectRange(VaultEntry entry) {
    final paths = _visibleEntries.map((e) => e.path).toList();
    final from = paths.indexOf(_selectionAnchor!);
    final to = paths.indexOf(entry.path);
    if (from == -1 || to == -1) return _toggleSelection(entry);
    setState(() {
      for (final selected in _visibleEntries.sublist(from < to ? from : to, (from < to ? to : from) + 1)) {
        _selection[selected.path] = selected;
      }
    });
  }

  void _selectAll() => setState(() {
    for (final entry in _visibleEntries) {
      _selection[entry.path] = entry;
    }
  });

  void _clearSelection() => setState(() {
    _selection.clear();
    _selectionAnchor = null;
  });

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
    if (folder == _directory) return;
    setState(() => _hidden.addAll(entries.map((e) => e.path)));
    _clearSelection();
    final moved = await _actions.moveMany(entries, folder);
    if (!mounted) return;
    await ref.read(folderProvider(_directory).future).catchError((_) => <VaultEntry>[]);
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
    await ref.read(folderProvider(_directory).future).catchError((_) => <VaultEntry>[]);
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
    if (deleted) {
      await ref.read(folderProvider(parentVaultPath(entry.path)).future).catchError((_) => <VaultEntry>[]);
    }
    if (mounted) setState(() => _hidden.remove(entry.path));
  }

  @override
  Widget build(BuildContext context) {
    final searching = _query.isNotEmpty;
    return PopScope(
      canPop: _directory.isEmpty && !searching && !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) return _clearSelection();
        if (searching) return _open(_directory);
        _open(parentVaultPath(_directory));
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _clearSelection,
          const SingleActivator(LogicalKeyboardKey.keyA, control: true): _selectAll,
          const SingleActivator(LogicalKeyboardKey.keyA, meta: true): _selectAll,
          const SingleActivator(LogicalKeyboardKey.delete): () {
            if (_selecting) _deleteSelected();
          },
        },
        child: Focus(
          focusNode: _shortcutsFocus,
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: _selecting && !searching ? _selectionBar() : _searchHeader(),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    child: searching
                        ? const SizedBox(width: double.infinity)
                        : _Breadcrumbs(directory: _directory, onOpen: _open),
                  ),
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
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
    );
  }

  Widget _selectionBar() {
    final count = _selection.length;
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
            if (filesOnly && !_onPhone)
              IconButton(
                key: const Key('saveSelected'),
                tooltip: kIsWeb ? 'Download' : 'Save decrypted copies',
                icon: const Icon(Icons.download_outlined),
                onPressed: _saveSelected,
              ),
            if (filesOnly && canShareFiles)
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
              onPressed: _moveSelected,
            ),
            IconButton(
              key: const Key('deleteSelected'),
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteSelected,
            ),
          ],
        ),
      ),
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
                direction: _selecting ? DismissDirection.none : DismissDirection.endToStart,
                background: const _DeleteBackground(),
                confirmDismiss: (_) => confirmDelete(context, entry),
                onDismissed: (_) => _deleteOptimistically(entry),
                child: EntryRow(
                  key: Key('entry:${entry.path}'),
                  entry: entry,
                  vault: _vault,
                  transfer: transfers[entry.path],
                  onTap: () => _onTap(entry),
                  onMenu: () => _onMenu(entry),
                  onLongPress: () => _toggleSelection(entry),
                  onIconTap: () => _toggleSelection(entry),
                  selected: _selecting ? _selection.containsKey(entry.path) : null,
                ),
              );
            },
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
        if (entries.isEmpty) {
          return _Message(
            icon: Icons.search_off,
            title: 'No results',
            detail: 'Nothing in the vault matches "$_query".',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final parent = parentVaultPath(entry.path);
            return EntryRow(
              key: Key('result:${entry.path}'),
              entry: entry,
              vault: _vault,
              transfer: transfers[entry.path],
              subtitleOverride: 'in ${parent.isEmpty ? 'Vault' : parent} · ${describeEntry(entry)}',
              onTap: () => entry.isDir ? _open(entry.path) : _actions.run(entry, EntryAction.open),
              onMenu: () => _onMenu(entry),
            );
          },
        );
      },
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
