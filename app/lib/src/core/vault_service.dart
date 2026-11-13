import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptdrive_native/cryptdrive_native.dart';
import 'package:path/path.dart' as p;

/// rclone remote names the app creates; exported as-is in rclone.conf.
abstract final class RemoteNames {
  static const googleDrive = 'gdrive';
  static const localFolder = 'localstore';
  static const browserMemory = 'memorystore';
  static const vault = 'vault';
}

enum StorageKind { googleDrive, localFolder, browserMemory, other }

class SetupStatus {
  const SetupStatus({this.storageRemote, this.storageKind, this.vaultRemote, this.clientId});

  final String? storageRemote;
  final StorageKind? storageKind;
  final String? vaultRemote;
  final String? clientId;

  bool get hasStorage => storageRemote != null;
  bool get hasVault => vaultRemote != null;
}

class VaultEntry {
  const VaultEntry({
    required this.path,
    required this.name,
    required this.isDir,
    required this.size,
    required this.modTime,
    this.mimeType,
  });

  factory VaultEntry.fromRclone(Map<String, dynamic> item) => VaultEntry(
    path: item['Path'] as String,
    name: item['Name'] as String,
    isDir: item['IsDir'] as bool? ?? false,
    size: (item['Size'] as num?)?.toInt() ?? -1,
    modTime: DateTime.tryParse(item['ModTime'] as String? ?? ''),
    mimeType: item['MimeType'] as String?,
  );

  /// Path inside the vault, '/'-separated, no leading slash.
  final String path;
  final String name;
  final bool isDir;
  final int size;
  final DateTime? modTime;
  final String? mimeType;
}

class InvalidTokenException implements Exception {
  InvalidTokenException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Everything CryptDrive does with the vault, expressed as rclone rc calls.
class VaultService {
  VaultService(this.rclone, {this.openedFilesDir});

  final Rclone rclone;

  /// Holds decrypted copies handed to other apps; wiped on start and exit.
  final Directory? openedFilesDir;

  /// Max bytes a single `operations/getfile` call may return.
  static const previewMaxBytes = 2 * 1024 * 1024;

  static const driveScope = 'drive';

  Future<Map<String, Map<String, dynamic>>> _remotes() async {
    final dump = await rclone.call('config/dump');
    return dump.map((name, value) => MapEntry(name, Map<String, dynamic>.from(value as Map)));
  }

  Future<SetupStatus> status() async {
    final remotes = await _remotes();
    String? vaultRemote;
    if (remotes[RemoteNames.vault]?['type'] == 'crypt') {
      vaultRemote = RemoteNames.vault;
    } else {
      final cryptRemotes = remotes.entries.where((entry) => entry.value['type'] == 'crypt').map((e) => e.key);
      vaultRemote = cryptRemotes.isEmpty ? null : (cryptRemotes.toList()..sort()).first;
    }

    String? storageRemote;
    if (vaultRemote != null) {
      final wrapped = remotes[vaultRemote]!['remote'] as String? ?? '';
      final colon = wrapped.indexOf(':');
      final wrappedRemote = colon > 0 ? wrapped.substring(0, colon) : null;
      if (wrappedRemote != null && remotes.containsKey(wrappedRemote)) storageRemote = wrappedRemote;
    }
    storageRemote ??= [
      RemoteNames.googleDrive,
      RemoteNames.localFolder,
      RemoteNames.browserMemory,
    ].where(remotes.containsKey).firstOrNull;

    final storageType = storageRemote == null ? null : remotes[storageRemote]!['type'];
    return SetupStatus(
      storageRemote: storageRemote,
      storageKind: switch (storageType) {
        null => null,
        'drive' => StorageKind.googleDrive,
        'local' => StorageKind.localFolder,
        'memory' => StorageKind.browserMemory,
        _ => StorageKind.other,
      },
      vaultRemote: vaultRemote,
      clientId: storageType == 'drive' ? remotes[storageRemote]!['client_id'] as String? : null,
    );
  }

  /// Runs Google's consent flow in process (rclone's loopback server on
  /// 127.0.0.1:53682) and returns the oauth2.Token JSON.
  Future<String> authorizeGoogleDrive({
    required String clientId,
    required String clientSecret,
    required Future<void> Function(Uri authUrl) openUrl,
  }) async {
    final started = await rclone.call('cryptdrive/authorize', {
      'backend': 'drive',
      'client_id': clientId,
      'client_secret': clientSecret,
      'scope': driveScope,
      '_async': true,
    });
    final jobId = started['jobid'] as int;
    var urlOpened = false;
    while (true) {
      final job = await rclone.call('job/status', {'jobid': jobId});
      if (job['finished'] == true) {
        if (job['success'] != true) {
          throw RcloneException('cryptdrive/authorize', 500, job['error']?.toString() ?? 'authorization failed');
        }
        return (job['output'] as Map)['token'] as String;
      }
      if (!urlOpened) {
        final oauth = await rclone.call('config/oauthstatus');
        if (oauth['status'] == 'running') {
          urlOpened = true;
          await openUrl(Uri.parse(oauth['authUrl'] as String));
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  Future<void> cancelAuthorization() async {
    try {
      if ((await rclone.call('config/oauthstatus'))['status'] != 'running') return;
      await rclone.call('config/oauthstop');
    } on RcloneException {
      // No authorization in progress.
    }
  }

  /// Checks that [tokenJson] is an oauth2.Token, as printed by `rclone authorize`.
  static String normalizeToken(String tokenJson) {
    var text = tokenJson.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start == -1 || end < start) throw InvalidTokenException('No JSON object found in the token.');
    text = text.substring(start, end + 1);
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw InvalidTokenException('Token is not valid JSON: ${error.message}');
    }
    if (decoded is! Map || decoded['access_token'] is! String) {
      throw InvalidTokenException('Token JSON has no access_token.');
    }
    if (decoded['refresh_token'] is! String) {
      throw InvalidTokenException('Token JSON has no refresh_token: access would expire within the hour.');
    }
    return jsonEncode(decoded);
  }

  Future<void> connectGoogleDrive({
    required String clientId,
    required String clientSecret,
    required String tokenJson,
  }) async {
    await rclone.call('config/create', {
      'name': RemoteNames.googleDrive,
      'type': 'drive',
      'parameters': {
        'client_id': clientId,
        'client_secret': clientSecret,
        'scope': driveScope,
        'token': normalizeToken(tokenJson),
        'config_is_local': 'false',
      },
      'opt': {'nonInteractive': true, 'obscure': true},
    });
  }

  /// Replaces the OAuth client; the token is tied to the client, so a new one is required.
  Future<void> updateGoogleDriveClient({
    required String clientId,
    required String clientSecret,
    required String tokenJson,
  }) async {
    await rclone.call('config/update', {
      'name': RemoteNames.googleDrive,
      'parameters': {'client_id': clientId, 'client_secret': clientSecret, 'token': normalizeToken(tokenJson)},
      'opt': {'nonInteractive': true, 'obscure': true},
    });
  }

  /// Browser only: storage that lives in this tab's memory, lost on reload (testing, demos).
  Future<void> connectBrowserMemory() async {
    await rclone.call('config/create', {
      'name': RemoteNames.browserMemory,
      'type': 'memory',
      'parameters': <String, dynamic>{},
      'opt': {'nonInteractive': true},
    });
  }

  /// A plain local folder standing in for Google Drive (testing, or no account).
  Future<void> connectLocalFolder() async {
    await rclone.call('config/create', {
      'name': RemoteNames.localFolder,
      'type': 'local',
      'parameters': <String, dynamic>{},
      'opt': {'nonInteractive': true},
    });
  }

  String _storageRoot(String storageRemote, String folder) {
    final trimmed = folder.trim();
    final cleanFolder = trimmed.length > 1 ? trimmed.replaceAll(RegExp(r'/+$'), '') : trimmed;
    return '$storageRemote:$cleanFolder';
  }

  /// Creates the crypt remote; with [mustExist] it adopts an existing vault folder instead.
  Future<void> configureVault({
    required String storageRemote,
    required String folder,
    required String password,
    String salt = '',
    bool mustExist = false,
  }) async {
    if (password.isEmpty) throw ArgumentError('A vault password is required.');
    final storageRoot = _storageRoot(storageRemote, folder);
    if (mustExist) {
      await rclone.call('operations/list', {
        'fs': storageRoot,
        'remote': '',
        'opt': {'dirsOnly': true},
      });
    }
    await rclone.call('config/create', {
      'name': RemoteNames.vault,
      'type': 'crypt',
      'parameters': {
        'remote': storageRoot,
        'password': password,
        if (salt.isNotEmpty) 'password2': salt,
        'filename_encryption': 'standard',
        'directory_name_encryption': 'true',
      },
      'opt': {'nonInteractive': true, 'obscure': true},
    });
    if (!mustExist) {
      await rclone.call('operations/mkdir', {'fs': '${RemoteNames.vault}:', 'remote': ''});
    }
  }

  Future<String> _vault() async {
    final vaultRemote = (await status()).vaultRemote;
    if (vaultRemote == null) throw StateError('No vault is configured.');
    return '$vaultRemote:';
  }

  Future<List<VaultEntry>> list(String directory) async {
    final reply = await rclone.call('operations/list', {'fs': await _vault(), 'remote': directory});
    final entries = (reply['list'] as List).map((item) => VaultEntry.fromRclone(item as Map<String, dynamic>)).toList()
      ..sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return entries;
  }

  /// Files and folders anywhere in the vault whose name contains [query], case-insensitively.
  Future<List<VaultEntry>> search(String query, {int limit = 200}) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return [];
    final reply = await rclone.call('operations/list', {
      'fs': await _vault(),
      'remote': '',
      'opt': {'recurse': true},
    });
    return (reply['list'] as List)
        .map((item) => VaultEntry.fromRclone(item as Map<String, dynamic>))
        .where((entry) => entry.name.toLowerCase().contains(needle))
        .take(limit)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<void> createFolder(String path) async {
    await rclone.call('operations/mkdir', {'fs': await _vault(), 'remote': path});
  }

  /// Renames or moves a file or folder inside the vault.
  Future<void> move(VaultEntry entry, String destinationPath) async {
    final vault = await _vault();
    if (!entry.isDir) {
      await rclone.runJob('operations/movefile', {
        'srcFs': vault,
        'srcRemote': entry.path,
        'dstFs': vault,
        'dstRemote': destinationPath,
      });
      return;
    }
    // operations/movefile only moves files; a folder moves as a server-side sync/move.
    await rclone.runJob('sync/move', {
      'srcFs': '$vault${entry.path}',
      'dstFs': '$vault$destinationPath',
      'deleteEmptySrcDirs': true,
      'createEmptySrcDirs': true,
    });
    final leftover = await rclone.call('operations/stat', {'fs': vault, 'remote': entry.path});
    if (leftover['item'] != null) {
      await rclone.call('operations/rmdir', {'fs': vault, 'remote': entry.path});
    }
  }

  Future<void> delete(VaultEntry entry) async {
    final vault = await _vault();
    if (entry.isDir) {
      await rclone.runJob('operations/purge', {'fs': vault, 'remote': entry.path});
    } else {
      await rclone.call('operations/deletefile', {'fs': vault, 'remote': entry.path});
    }
  }

  /// Decrypts [entry] into [openedFilesDir] for an OS opener or share sheet.
  Future<File> decryptToTemp(VaultEntry entry, {void Function(JobProgress)? onProgress}) async {
    final targetDir = Directory(p.join(openedFilesDir!.path, _randomId()));
    await targetDir.create(recursive: true);
    await rclone.runJob('operations/copyfile', {
      'srcFs': await _vault(),
      'srcRemote': entry.path,
      'dstFs': targetDir.path,
      'dstRemote': entry.name,
    }, onProgress: onProgress);
    return File(p.join(targetDir.path, entry.name));
  }

  /// Decrypts [entry] into [directory] under its own name (native).
  Future<File> decryptInto(VaultEntry entry, Directory directory, {void Function(JobProgress)? onProgress}) async {
    await rclone.runJob('operations/copyfile', {
      'srcFs': await _vault(),
      'srcRemote': entry.path,
      'dstFs': directory.path,
      'dstRemote': entry.name,
    }, onProgress: onProgress);
    return File(p.join(directory.path, entry.name));
  }

  /// The first bytes of [entry] (at most [previewMaxBytes]), decrypted in memory.
  Future<Uint8List> readHead(VaultEntry entry, {int maxBytes = previewMaxBytes}) async {
    final count = min(maxBytes, previewMaxBytes);
    final reply = await rclone.call('operations/getfile', {
      'fs': await _vault(),
      'remote': entry.path,
      'count': count,
      'base64': true,
    });
    return base64Decode(reply['result'] as String);
  }

  /// Encrypts and uploads a local file (already staged on disk) into [directory].
  Future<void> upload(File localFile, String directory, {String? name, void Function(JobProgress)? onProgress}) async {
    final fileName = name ?? p.basename(localFile.path);
    await rclone.runJob('operations/copyfile', {
      'srcFs': localFile.parent.absolute.path,
      'srcRemote': p.basename(localFile.path),
      'dstFs': await _vault(),
      'dstRemote': joinVaultPath(directory, fileName),
    }, onProgress: onProgress);
  }

  /// Browser: encrypts and uploads [data] as [name] into [directory].
  Future<void> uploadBytes(
    Uint8List data,
    String directory,
    String name, {
    void Function(JobProgress)? onProgress,
  }) async {
    await rclone.putFile(await _vault(), joinVaultPath(directory, name), data, onProgress: onProgress);
  }

  /// Browser: downloads and decrypts [entry] in [chunkBytes] pieces, kept as separate parts.
  Future<List<Uint8List>> downloadBytes(
    VaultEntry entry, {
    void Function(JobProgress)? onProgress,
    int chunkBytes = 8 * 1024 * 1024,
  }) async {
    final vault = await _vault();
    final parts = <Uint8List>[];
    var offset = 0;
    while (true) {
      final part = await rclone.readFile(vault, entry.path, offset: offset, count: chunkBytes);
      if (part.isEmpty) break;
      parts.add(part);
      offset += part.length;
      onProgress?.call(JobProgress(bytes: offset, totalBytes: entry.size));
      if (part.length < chunkBytes || (entry.size >= 0 && offset >= entry.size)) break;
    }
    return parts;
  }

  Future<String> exportRcloneConf() async => (await rclone.call('cryptdrive/exportconfig'))['conf'] as String;

  Future<List<String>> importRcloneConf(String confText, {String? password}) async {
    final reply = await rclone.call('cryptdrive/importconfig', {
      'conf': confText,
      if (password != null && password.isNotEmpty) 'password': password,
    });
    return (reply['remotes'] as List).cast<String>();
  }

  Future<void> wipeOpenedFiles() async {
    final directory = openedFilesDir;
    if (directory != null && await directory.exists()) await directory.delete(recursive: true);
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(12, (_) => random.nextInt(36).toRadixString(36)).join();
  }
}

String joinVaultPath(String directory, String name) => directory.isEmpty ? name : '$directory/$name';

String parentVaultPath(String path) {
  final slash = path.lastIndexOf('/');
  return slash == -1 ? '' : path.substring(0, slash);
}
