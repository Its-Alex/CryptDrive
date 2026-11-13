import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:path/path.dart' as p;

import 'vault_service.dart';

/// A local file to upload and the vault path it goes to.
typedef LocalUpload = ({String localPath, String vaultPath});

/// A file read into memory, at its path relative to the drop target.
typedef MemoryUpload = ({String path, Uint8List bytes});

/// The vault folders and files a dropped folder turns into.
class FolderUploadPlan {
  const FolderUploadPlan({required this.folders, required this.files});

  /// Vault paths to create, parents before their children.
  final List<String> folders;

  final List<LocalUpload> files;

  bool get isEmpty => files.isEmpty && folders.isEmpty;
}

/// Mirrors the tree under [root] into `<target>/<name of root>`, empty folders
/// included.
///
/// Symlinks are skipped: they can lead outside the dropped tree, or loop.
Future<FolderUploadPlan> planFolderUpload(Directory root, String target) async {
  final folders = <String>[];
  final files = <LocalUpload>[];
  Future<void> walk(Directory directory, String vaultDirectory) async {
    folders.add(vaultDirectory);
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        await walk(entity, joinVaultPath(vaultDirectory, name));
      } else if (entity is File) {
        files.add((localPath: entity.path, vaultPath: joinVaultPath(vaultDirectory, name)));
      }
    }
  }

  await walk(root, joinVaultPath(target, p.basename(p.normalize(root.path))));
  return FolderUploadPlan(folders: folders, files: files);
}

/// Flattens a folder dropped in a browser, where entries carry their bytes and
/// no path at all. Paths are relative to the drop target.
///
/// Empty folders are lost: the browser gives the app nothing to create them
/// with except a directory with no children, which the memory backend drops
/// anyway.
Future<List<MemoryUpload>> planDroppedFolderMemory(DropItemDirectory folder) async {
  final uploads = <MemoryUpload>[];
  Future<void> walk(DropItem item, String path) async {
    if (item is DropItemDirectory) {
      for (final child in item.children) {
        await walk(child, joinVaultPath(path, child.name));
      }
    } else {
      uploads.add((path: path, bytes: await item.readAsBytes()));
    }
  }

  await walk(folder, folder.name);
  return uploads;
}
