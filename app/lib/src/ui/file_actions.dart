import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../core/drop_folder_plan.dart';
import '../core/perf_log.dart';
import '../core/drive_shortcuts.dart';
import '../core/vault_service.dart';
import '../platform/browser_api.dart' as browser;
import '../state/providers.dart';
import '../state/recent_files.dart';
import '../state/transfers.dart';
import 'entry_widgets.dart';
import 'widgets.dart';

enum EntryAction { open, preview, share, saveCopy, rename, move, delete }

bool get canShareFiles =>
    !kIsWeb &&
    const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }.contains(defaultTargetPlatform);

bool canPreview(VaultEntry entry) {
  final mime = entry.mimeType ?? '';
  return mime.startsWith('text/') || mime == 'application/json' || ThumbnailCache.supports(entry);
}

Future<EntryAction?> showEntryActions(BuildContext context, VaultEntry entry, VaultService vault) {
  ListTile item(EntryAction action, IconData icon, String label, {bool destructive = false}) {
    final color = destructive ? Theme.of(context).colorScheme.error : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: () => Navigator.of(context).pop(action),
    );
  }

  return showModalBottomSheet<EntryAction>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: EntryIcon(entry: entry, vault: vault),
            title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(describeEntry(entry)),
          ),
          const Divider(height: 1),
          if (!entry.isDir) ...[
            item(EntryAction.open, Icons.open_in_new, 'Open'),
            if (canPreview(entry)) item(EntryAction.preview, Icons.visibility_outlined, 'Preview'),
            if (canShareFiles) item(EntryAction.share, Icons.share_outlined, 'Share'),
            item(EntryAction.saveCopy, Icons.download_outlined, 'Save decrypted copy…'),
          ],
          item(EntryAction.rename, Icons.drive_file_rename_outline, 'Rename'),
          item(EntryAction.move, Icons.drive_file_move_outline, 'Move'),
          item(EntryAction.delete, Icons.delete_outline, 'Delete', destructive: true),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Runs entry actions from any screen, with inline progress on the entry's row.
class FileActions {
  FileActions(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  VaultService get _vault => ref.read(environmentProvider).requireValue.vault;
  Transfers get _transfers => ref.read(transfersProvider.notifier);

  void _refresh(String directory) => ref.invalidate(folderProvider(directory));

  Future<File?> _decrypt(VaultEntry entry) async {
    _transfers.start(TransferKind.decrypt, entry.path);
    try {
      return await _vault.decryptToTemp(
        entry,
        onProgress: (progress) => _transfers.progress(entry.path, progress.fraction),
      );
    } catch (error) {
      if (context.mounted) showMessage(context, describeError(error));
      return null;
    } finally {
      _transfers.finish(entry.path);
    }
  }

  /// Browser: decrypts [entry] in memory and hands it to the browser.
  Future<bool> _deliverInBrowser(VaultEntry entry, {required bool openInNewTab}) async {
    _transfers.start(TransferKind.decrypt, entry.path);
    try {
      final parts = await _vault.downloadBytes(
        entry,
        onProgress: (progress) => _transfers.progress(entry.path, progress.fraction),
      );
      browser.deliverFile(entry.name, parts, mimeType: entry.mimeType, openInNewTab: openInNewTab);
      return true;
    } catch (error) {
      if (context.mounted) showMessage(context, describeError(error));
      return false;
    } finally {
      _transfers.finish(entry.path);
    }
  }

  Future<bool> _attempt(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (error) {
      if (context.mounted) showMessage(context, describeError(error));
      return false;
    }
  }

  Future<void> upload(List<File> files, String directory, {bool deleteStaged = false}) async {
    await Future.wait(
      files.map((file) async {
        final path = joinVaultPath(directory, p.basename(file.path));
        _transfers.start(TransferKind.upload, path);
        try {
          await _vault.upload(file, directory, onProgress: (progress) => _transfers.progress(path, progress.fraction));
          final size = await file.length();
          await ref
              .read(recentFilesProvider.notifier)
              .record(
                VaultEntry(path: path, name: p.basename(path), isDir: false, size: size, modTime: DateTime.now()),
                RecentAction.uploaded,
              );
        } catch (error) {
          if (context.mounted) showMessage(context, 'Upload of ${p.basename(path)} failed: ${describeError(error)}');
        } finally {
          _transfers.finish(path);
          if (deleteStaged && await file.exists()) await file.delete();
          _refresh(directory);
        }
      }),
    );
  }

  /// Browser: encrypts and uploads files picked in the browser, kept in memory meanwhile.
  Future<void> uploadPicked(List<XFile> files, String directory) async {
    await Future.wait(
      files.map((file) async {
        final path = joinVaultPath(directory, file.name);
        final watch = Stopwatch()..start();
        perfLog('[upload] ${file.name}: row up');
        // The row goes up before the bytes are read: a large file spends seconds in
        // readAsBytes() and in the copies down to the worker, all before rclone starts.
        _transfers.start(TransferKind.upload, path);
        try {
          final bytes = await file.readAsBytes();
          perfLog('[upload] ${file.name}: ${bytes.length} B read at ${watch.elapsedMilliseconds} ms');
          await _vault.uploadBytes(
            bytes,
            directory,
            file.name,
            onProgress: (progress) => _transfers.progress(
              path,
              progress.fraction ?? (bytes.isEmpty ? null : (progress.bytes / bytes.length).clamp(0.0, 1.0).toDouble()),
            ),
          );
          perfLog('[upload] ${file.name}: engine done at ${watch.elapsedMilliseconds} ms');
          await ref
              .read(recentFilesProvider.notifier)
              .record(
                VaultEntry(path: path, name: file.name, isDir: false, size: bytes.length, modTime: DateTime.now()),
                RecentAction.uploaded,
              );
        } catch (error) {
          if (context.mounted) showMessage(context, 'Upload of ${file.name} failed: ${describeError(error)}');
        } finally {
          await _refreshThenFinish(directory, path);
          perfLog('[upload] ${file.name}: listed at ${watch.elapsedMilliseconds} ms');
        }
      }),
    );
  }

  /// Re-lists before dropping the progress row: dropping it first leaves the file
  /// invisible for as long as the folder takes to list again (seconds on Drive).
  Future<void> _refreshThenFinish(String directory, String path) async {
    ref.invalidate(folderProvider(directory));
    try {
      await ref.read(folderProvider(directory).future);
    } catch (_) {
      // The listing renders its own error; the upload outcome is already reported.
    } finally {
      _transfers.finish(path);
    }
  }

  /// Uploads a dropped folder: creates every folder it holds, then its files a
  /// few at a time, with one summary message at the end.
  Future<void> uploadFolder(FolderUploadPlan plan, String target) async {
    for (final folder in plan.folders) {
      await _attempt(() => _vault.createFolder(folder));
    }
    final failures = <String>[];
    final refreshed = <String>{target};
    await _forEachLimited(plan.files, (file) async {
      final directory = parentVaultPath(file.vaultPath);
      _transfers.start(TransferKind.upload, file.vaultPath);
      try {
        await _vault.upload(
          File(file.localPath),
          directory,
          name: p.basename(file.vaultPath),
          onProgress: (progress) => _transfers.progress(file.vaultPath, progress.fraction),
        );
      } catch (error) {
        failures.add('${p.basename(file.vaultPath)}: ${describeError(error)}');
      } finally {
        await _refreshThenFinish(directory, file.vaultPath);
        refreshed.add(directory);
      }
    });
    refreshed.forEach(_refresh);
    if (context.mounted) _reportFolderUpload(plan.folders.first, plan.files.length, failures);
  }

  /// Browser: the same tree, with every file already in memory.
  Future<void> uploadFolderInMemory(List<MemoryUpload> files, String target) async {
    final failures = <String>[];
    final refreshed = <String>{target};
    await _forEachLimited(files, (file) async {
      final path = joinVaultPath(target, file.path);
      final directory = parentVaultPath(path);
      _transfers.start(TransferKind.upload, path);
      try {
        await _vault.uploadBytes(
          file.bytes,
          directory,
          p.basename(path),
          onProgress: (progress) => _transfers.progress(path, progress.fraction),
        );
      } catch (error) {
        failures.add('${p.basename(path)}: ${describeError(error)}');
      } finally {
        await _refreshThenFinish(directory, path);
        refreshed.add(directory);
      }
    });
    refreshed.forEach(_refresh);
    final destination = files.isEmpty ? target : joinVaultPath(target, files.first.path.split('/').first);
    if (context.mounted) _reportFolderUpload(destination, files.length, failures);
  }

  /// A dropped tree can hold thousands of files: never one rclone job per file
  /// at once.
  static const uploadConcurrency = 4;

  Future<void> _forEachLimited<T>(List<T> items, Future<void> Function(T) task) async {
    var next = 0;
    Future<void> worker() async {
      while (next < items.length) {
        await task(items[next++]);
      }
    }

    await Future.wait([for (var i = 0; i < uploadConcurrency; i++) worker()]);
  }

  void _reportFolderUpload(String destination, int total, List<String> failures) {
    final where = destination.isEmpty ? 'the vault root' : destination;
    if (failures.isEmpty) {
      showMessage(
        context,
        total == 0 ? 'Created $where' : 'Uploaded $total ${total == 1 ? 'file' : 'files'} to $where',
      );
      return;
    }
    showMessage(
      context,
      'Uploaded ${total - failures.length} of $total files to $where; '
      '${failures.first}${failures.length == 1 ? '' : ' and ${failures.length - 1} more'} failed',
    );
  }

  /// Returns true when the entry left its folder (moved or deleted).
  Future<bool> run(VaultEntry entry, EntryAction action) async {
    final parent = parentVaultPath(entry.path);
    switch (action) {
      case EntryAction.open when kIsWeb:
        if (await _deliverInBrowser(entry, openInNewTab: opensInBrowserTab(entry))) {
          await ref.read(recentFilesProvider.notifier).record(entry, RecentAction.opened);
        }
        return false;
      case EntryAction.saveCopy when kIsWeb:
        await _deliverInBrowser(entry, openInNewTab: false);
        return false;
      case EntryAction.open:
        final file = await _decrypt(entry);
        if (file == null) return false;
        await ref.read(recentFilesProvider.notifier).record(entry, RecentAction.opened);
        final result = await OpenFilex.open(file.path);
        if (result.type != ResultType.done && context.mounted) {
          showMessage(context, 'No app can open ${entry.name}: ${result.message}');
        }
        return false;
      case EntryAction.preview:
        try {
          final bytes = await _vault.readHead(entry);
          if (context.mounted) await showPreview(context, entry, bytes);
        } catch (error) {
          if (context.mounted) showMessage(context, describeError(error));
        }
        return false;
      case EntryAction.share:
        final file = await _decrypt(entry);
        if (file != null) await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
        return false;
      case EntryAction.saveCopy:
        final file = await _decrypt(entry);
        if (file == null) return false;
        final saved = await FilePicker.saveFile(fileName: entry.name, bytes: await file.readAsBytes());
        if (saved != null && context.mounted) showMessage(context, 'Saved a decrypted copy of ${entry.name}');
        return false;
      case EntryAction.rename:
        final name = await askText(
          context,
          title: 'Rename',
          label: 'New name',
          initialValue: entry.name,
          confirmLabel: 'Rename',
        );
        if (name == null || name.isEmpty || name == entry.name) return false;
        final renamed = await _attempt(() => _vault.move(entry, joinVaultPath(parent, name)));
        if (renamed) await ref.read(recentFilesProvider.notifier).forget(entry.path);
        _refresh(parent);
        return false;
      case EntryAction.move:
        final destination = await askText(
          context,
          title: 'Move ${entry.name}',
          label: 'Destination folder (empty = vault root)',
          initialValue: parent,
          confirmLabel: 'Move',
        );
        if (destination == null) return false;
        final folder = destination.replaceAll(RegExp(r'^/+|/+$'), '');
        if (folder == parent) return false;
        final moved = await _attempt(() => _vault.move(entry, joinVaultPath(folder, entry.name)));
        if (moved) await ref.read(recentFilesProvider.notifier).forget(entry.path);
        _refresh(parent);
        _refresh(folder);
        return moved;
      case EntryAction.delete:
        if (!await confirmDelete(context, entry)) return false;
        return delete(entry);
    }
  }

  /// Moves every entry into [folder]; returns the paths that moved.
  Future<Set<String>> moveMany(List<VaultEntry> entries, String folder) async {
    final moved = <String>{};
    final sources = <String>{};
    for (final entry in entries) {
      if (parentVaultPath(entry.path) == folder) continue;
      if (await _attempt(() => _vault.move(entry, joinVaultPath(folder, entry.name)))) {
        moved.add(entry.path);
        sources.add(parentVaultPath(entry.path));
        await ref.read(recentFilesProvider.notifier).forget(entry.path);
      }
    }
    sources.forEach(_refresh);
    _refresh(folder);
    return moved;
  }

  /// Copies every entry into [folder]; returns the paths of the new copies.
  /// A name already present in the destination is left alone, as Drive does.
  Future<Set<String>> copyMany(List<VaultEntry> entries, String folder) async {
    final copied = <String>{};
    final existing = {for (final entry in await _vault.list(folder)) entry.name};
    for (final entry in entries) {
      final destination = copiedPath(entry.path, folder);
      if (destination == entry.path || existing.contains(entry.name)) continue;
      if (await _attempt(() => _vault.copy(entry, destination))) {
        copied.add(destination);
        existing.add(entry.name);
      }
    }
    _refresh(folder);
    return copied;
  }

  /// Deletes every entry; returns the paths that were deleted.
  Future<Set<String>> deleteMany(List<VaultEntry> entries) async {
    final deleted = <String>{};
    await Future.wait(
      entries.map((entry) async {
        if (await _attempt(() => _vault.delete(entry))) {
          deleted.add(entry.path);
          await ref.read(recentFilesProvider.notifier).forget(entry.path);
        }
      }),
    );
    entries.map((entry) => parentVaultPath(entry.path)).toSet().forEach(_refresh);
    return deleted;
  }

  /// Decrypts files into a folder the user picks (desktop) or as browser downloads (web).
  Future<void> saveCopies(List<VaultEntry> files) async {
    if (kIsWeb) {
      for (final file in files) {
        await _deliverInBrowser(file, openInNewTab: false);
      }
      return;
    }
    final target = await FilePicker.getDirectoryPath(dialogTitle: 'Save decrypted copies to');
    if (target == null) return;
    var saved = 0;
    await Future.wait(
      files.map((file) async {
        _transfers.start(TransferKind.decrypt, file.path);
        try {
          await _vault.decryptInto(
            file,
            Directory(target),
            onProgress: (progress) => _transfers.progress(file.path, progress.fraction),
          );
          saved++;
        } catch (error) {
          if (context.mounted) showMessage(context, '${file.name}: ${describeError(error)}');
        } finally {
          _transfers.finish(file.path);
        }
      }),
    );
    if (context.mounted) showMessage(context, 'Saved $saved decrypted ${saved == 1 ? 'copy' : 'copies'} to $target');
  }

  /// Decrypts the files and opens the share sheet with all of them.
  Future<void> shareMany(List<VaultEntry> files) async {
    final decrypted = <File>[];
    for (final file in files) {
      final copy = await _decrypt(file);
      if (copy != null) decrypted.add(copy);
    }
    if (decrypted.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: [for (final file in decrypted) XFile(file.path)]));
  }

  Future<bool> delete(VaultEntry entry) async {
    final deleted = await _attempt(() => _vault.delete(entry));
    if (deleted) await ref.read(recentFilesProvider.notifier).forget(entry.path);
    _refresh(parentVaultPath(entry.path));
    return deleted;
  }
}

Future<bool> confirmDelete(BuildContext context, VaultEntry entry) => confirm(
  context,
  title: 'Delete ${entry.name}?',
  message: entry.isDir ? 'The folder and everything in it will be deleted.' : 'The file will be deleted.',
  confirmLabel: 'Delete',
);

Future<void> showPreview(BuildContext context, VaultEntry entry, Uint8List bytes) {
  final truncated = entry.size > bytes.length;
  final isImage = entry.mimeType?.startsWith('image/') ?? false;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(entry.name),
      content: SizedBox(
        width: 480,
        child: isImage && !truncated
            ? ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Text('Not a displayable image.'),
                ),
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

/// Types a browser shows itself; anything else is downloaded.
///
/// A blob URL runs in the app's origin: never open a type that can run scripts
/// (SVG, HTML…), or a file in the vault could read the stored config and password.
bool opensInBrowserTab(VaultEntry entry) {
  final mime = entry.mimeType ?? '';
  return (mime.startsWith('image/') && !mime.contains('svg')) ||
      mime.startsWith('video/') ||
      mime.startsWith('audio/') ||
      mime == 'application/pdf' ||
      mime == 'text/plain';
}
