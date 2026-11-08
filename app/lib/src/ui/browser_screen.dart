import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptdrive_native/cryptdrive_native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:share_plus/share_plus.dart';

import '../core/vault_service.dart';
import '../state/providers.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

enum _EntryAction { open, preview, share, saveCopy, rename, move, delete }

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  String _directory = '';
  Busy? _busy;
  StreamSubscription<List<SharedMediaFile>>? _sharedFiles;

  VaultService get _vault => ref.read(environmentProvider).requireValue.vault;

  bool get _canShareFiles => Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid || Platform.isIOS) {
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
    super.dispose();
  }

  void _refresh() => ref.invalidate(folderProvider(_directory));

  Future<T?> _run<T>(String label, Future<T> Function(void Function(JobProgress) onProgress) action) async {
    setState(() => _busy = Busy(label));
    try {
      return await action((progress) {
        if (mounted) setState(() => _busy = Busy(label, progress.fraction));
      });
    } catch (error) {
      if (mounted) showMessage(context, describeError(error));
      return null;
    } finally {
      if (mounted) setState(() => _busy = null);
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
    if (!proceed) return;
    await _uploadFiles([for (final file in files) File(file.path)], deleteStaged: true);
  }

  Future<void> _pickAndUpload() async {
    final picked = await FilePicker.pickFiles(dialogTitle: 'Upload to vault');
    if (picked.isEmpty) return;
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
      await _uploadFiles(staged);
    } finally {
      await stagingDir.delete(recursive: true);
    }
  }

  Future<void> _uploadFiles(List<File> files, {bool deleteStaged = false}) async {
    final directory = _directory;
    for (final (index, file) in files.indexed) {
      final label = 'Encrypting and uploading ${p.basename(file.path)} (${index + 1}/${files.length})';
      await _run(label, (onProgress) => _vault.upload(file, directory, onProgress: onProgress));
      if (deleteStaged && await file.exists()) await file.delete();
    }
    ref.invalidate(folderProvider(directory));
  }

  Future<void> _newFolder() async {
    final name = await askText(context, title: 'New folder', label: 'Folder name', confirmLabel: 'Create');
    if (name == null || name.isEmpty) return;
    await _run('Creating $name', (_) => _vault.createFolder(joinVaultPath(_directory, name)));
    _refresh();
  }

  Future<void> _onAction(VaultEntry entry, _EntryAction action) async {
    switch (action) {
      case _EntryAction.open:
        final file = await _run(
          'Decrypting ${entry.name}',
          (onProgress) => _vault.decryptToTemp(entry, onProgress: onProgress),
        );
        if (file == null) return;
        final result = await OpenFilex.open(file.path);
        if (result.type != ResultType.done && mounted) {
          showMessage(context, 'No app can open ${entry.name}: ${result.message}');
        }
      case _EntryAction.preview:
        final bytes = await _run('Loading preview', (_) => _vault.readHead(entry));
        if (bytes != null && mounted) await _showPreview(entry, bytes);
      case _EntryAction.share:
        final file = await _run(
          'Decrypting ${entry.name}',
          (onProgress) => _vault.decryptToTemp(entry, onProgress: onProgress),
        );
        if (file == null) return;
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
      case _EntryAction.saveCopy:
        final file = await _run(
          'Decrypting ${entry.name}',
          (onProgress) => _vault.decryptToTemp(entry, onProgress: onProgress),
        );
        if (file == null) return;
        final saved = await FilePicker.saveFile(fileName: entry.name, bytes: await file.readAsBytes());
        if (saved != null && mounted) showMessage(context, 'Saved a decrypted copy of ${entry.name}');
      case _EntryAction.rename:
        final name = await askText(
          context,
          title: 'Rename',
          label: 'New name',
          initialValue: entry.name,
          confirmLabel: 'Rename',
        );
        if (name == null || name.isEmpty || name == entry.name) return;
        await _run(
          'Renaming ${entry.name}',
          (_) => _vault.move(entry, joinVaultPath(parentVaultPath(entry.path), name)),
        );
        _refresh();
      case _EntryAction.move:
        final destination = await askText(
          context,
          title: 'Move ${entry.name}',
          label: 'Destination folder (empty = vault root)',
          initialValue: parentVaultPath(entry.path),
          confirmLabel: 'Move',
        );
        if (destination == null) return;
        final folder = destination.replaceAll(RegExp(r'^/+|/+$'), '');
        if (folder == parentVaultPath(entry.path)) return;
        await _run('Moving ${entry.name}', (_) => _vault.move(entry, joinVaultPath(folder, entry.name)));
        _refresh();
        ref.invalidate(folderProvider(folder));
      case _EntryAction.delete:
        final proceed = await confirm(
          context,
          title: 'Delete ${entry.name}?',
          message: entry.isDir ? 'The folder and everything in it will be deleted.' : 'The file will be deleted.',
          confirmLabel: 'Delete',
        );
        if (!proceed) return;
        await _run('Deleting ${entry.name}', (_) => _vault.delete(entry));
        _refresh();
    }
  }

  Future<void> _showPreview(VaultEntry entry, Uint8List bytes) {
    final truncated = entry.size > bytes.length;
    final isImage = entry.mimeType?.startsWith('image/') ?? false;
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.name),
        content: SizedBox(
          width: 480,
          child: isImage && !truncated
              ? Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Text('Not a displayable image.'),
                )
              : SingleChildScrollView(
                  child: SelectableText(
                    utf8.decode(bytes, allowMalformed: true) + (truncated ? '\n…' : ''),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }

  bool _canPreview(VaultEntry entry) {
    final mime = entry.mimeType ?? '';
    final small = entry.size >= 0 && entry.size <= VaultService.previewMaxBytes;
    return mime.startsWith('text/') || (mime.startsWith('image/') && small) || mime == 'application/json';
  }

  @override
  Widget build(BuildContext context) {
    final listing = ref.watch(folderProvider(_directory));
    final segments = _directory.isEmpty ? <String>[] : _directory.split('/');
    return PopScope(
      canPop: _directory.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _directory = parentVaultPath(_directory));
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _directory.isEmpty
              ? const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.lock))
              : IconButton(
                  tooltip: 'Up',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: () => setState(() => _directory = parentVaultPath(_directory)),
                ),
          title: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(
              children: [
                TextButton(onPressed: () => setState(() => _directory = ''), child: const Text('Vault')),
                for (final (index, segment) in segments.indexed) ...[
                  const Icon(Icons.chevron_right, size: 18),
                  TextButton(
                    onPressed: () => setState(() => _directory = segments.sublist(0, index + 1).join('/')),
                    child: Text(segment),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh),
            IconButton(
              key: const Key('openSettings'),
              tooltip: 'Settings',
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            ),
          ],
          bottom: BusyBar(busy: _busy),
        ),
        body: listing.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ErrorView(error: error, onRetry: _refresh),
          data: (entries) => entries.isEmpty
              ? const Center(child: Text('This folder is empty.'))
              : RefreshIndicator(
                  onRefresh: () => ref.refresh(folderProvider(_directory).future),
                  child: ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) => _entryTile(entries[index]),
                  ),
                ),
        ),
        floatingActionButton: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            FloatingActionButton.small(
              key: const Key('newFolder'),
              heroTag: 'newFolder',
              tooltip: 'New folder',
              onPressed: _busy == null ? _newFolder : null,
              child: const Icon(Icons.create_new_folder),
            ),
            const SizedBox(height: 12),
            FloatingActionButton.extended(
              key: const Key('upload'),
              heroTag: 'upload',
              onPressed: _busy == null ? _pickAndUpload : null,
              icon: const Icon(Icons.upload),
              label: const Text('Upload'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(VaultEntry entry) {
    final subtitle = [
      if (!entry.isDir && entry.size >= 0) formatBytes(entry.size),
      if (entry.modTime != null) _formatDate(entry.modTime!.toLocal()),
    ].join(' · ');
    return ListTile(
      key: Key('entry:${entry.path}'),
      leading: Icon(entry.isDir ? Icons.folder : _iconFor(entry)),
      title: Text(entry.name),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      onTap: _busy != null
          ? null
          : () {
              if (entry.isDir) {
                setState(() => _directory = entry.path);
              } else {
                _onAction(entry, _EntryAction.open);
              }
            },
      trailing: PopupMenuButton<_EntryAction>(
        key: Key('menu:${entry.path}'),
        enabled: _busy == null,
        onSelected: (action) => _onAction(entry, action),
        itemBuilder: (context) => [
          if (!entry.isDir) ...[
            const PopupMenuItem(value: _EntryAction.open, child: Text('Open')),
            if (_canPreview(entry)) const PopupMenuItem(value: _EntryAction.preview, child: Text('Preview')),
            if (_canShareFiles) const PopupMenuItem(value: _EntryAction.share, child: Text('Share')),
            const PopupMenuItem(value: _EntryAction.saveCopy, child: Text('Save decrypted copy…')),
          ],
          const PopupMenuItem(value: _EntryAction.rename, child: Text('Rename')),
          const PopupMenuItem(value: _EntryAction.move, child: Text('Move')),
          const PopupMenuItem(value: _EntryAction.delete, child: Text('Delete')),
        ],
      ),
    );
  }

  IconData _iconFor(VaultEntry entry) {
    final mime = entry.mimeType ?? '';
    if (mime.startsWith('image/')) return Icons.image;
    if (mime.startsWith('video/')) return Icons.movie;
    if (mime.startsWith('audio/')) return Icons.audiotrack;
    if (mime.startsWith('text/')) return Icons.description;
    if (mime == 'application/pdf') return Icons.picture_as_pdf;
    return Icons.insert_drive_file;
  }

  String _formatDate(DateTime time) =>
      '${time.year}-${_two(time.month)}-${_two(time.day)} ${_two(time.hour)}:${_two(time.minute)}';

  String _two(int value) => value.toString().padLeft(2, '0');
}

String formatBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}
