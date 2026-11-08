import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'bindings.dart';

class RcloneException implements Exception {
  RcloneException(this.method, this.status, this.message);

  final String method;
  final int status;
  final String message;

  @override
  String toString() => 'rclone $method failed ($status): $message';
}

/// Transfer progress of a long rc call, from `core/stats`.
class JobProgress {
  const JobProgress({required this.bytes, required this.totalBytes});

  final int bytes;
  final int totalBytes;

  double? get fraction => totalBytes > 0 ? bytes / totalBytes : null;
}

/// Async facade over [CryptDriveBindings]: every native call runs on a
/// short-lived isolate so the UI isolate never blocks on network or crypto.
class Rclone {
  Rclone._(this._libraryPath);

  final String? _libraryPath;

  /// Starts rclone with its config file at [configPath] (an encrypted
  /// rclone.conf once a config password is set).
  static Future<Rclone> start({required String configPath, String? libraryPath}) async {
    final error = await Isolate.run(
      () => CryptDriveBindings(openCryptDriveLibrary(libraryPath)).initialize(configPath),
    );
    if (error != null) throw RcloneException('initialize', 500, error);
    return Rclone._(libraryPath);
  }

  /// Sets the key of the encrypted rclone.conf; throws if it can't decrypt the file on disk.
  Future<void> setConfigPassword(String password) async {
    final libraryPath = _libraryPath;
    final error = await Isolate.run(
      () => CryptDriveBindings(openCryptDriveLibrary(libraryPath)).setConfigPassword(password),
    );
    if (error != null) throw RcloneException('setConfigPassword', 400, error);
  }

  /// Calls rc [method] (https://rclone.org/rc/) and returns its JSON reply.
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    final libraryPath = _libraryPath;
    final input = jsonEncode(params);
    final reply = await Isolate.run(() => CryptDriveBindings(openCryptDriveLibrary(libraryPath)).rpc(method, input));
    final decoded = reply.output.isEmpty ? <String, dynamic>{} : jsonDecode(reply.output) as Map<String, dynamic>;
    if (reply.status != 200) {
      throw RcloneException(method, reply.status, decoded['error']?.toString() ?? reply.output);
    }
    return decoded;
  }

  static var _nextStatsGroup = 0;

  /// Runs a long rc [method] on its own isolate and reports transfer progress.
  ///
  /// The call is synchronous on that isolate, so it returns the moment rclone
  /// finishes; [onProgress] polls `core/stats` for the call's stats group meanwhile.
  Future<Map<String, dynamic>> runJob(
    String method,
    Map<String, dynamic> params, {
    void Function(JobProgress progress)? onProgress,
    Duration pollInterval = const Duration(milliseconds: 200),
  }) async {
    final group = 'cryptdrive/${_nextStatsGroup++}';
    final result = call(method, {...params, '_group': group});
    if (onProgress == null) return result;

    var finished = false;
    result.whenComplete(() => finished = true).ignore();
    while (!finished) {
      await Future.any([result, Future<void>.delayed(pollInterval)]).catchError((_) => null);
      if (finished) break;
      final stats = await call('core/stats', {'group': group});
      onProgress(
        JobProgress(
          bytes: (stats['bytes'] as num?)?.toInt() ?? 0,
          totalBytes: (stats['totalBytes'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return result;
  }

  /// Stops in-flight jobs, then finalizes the library.
  Future<void> shutdown() async {
    final libraryPath = _libraryPath;
    await Isolate.run(() => CryptDriveBindings(openCryptDriveLibrary(libraryPath)).finalize());
  }
}
