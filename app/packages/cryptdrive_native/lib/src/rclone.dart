import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'transport.dart';
import 'transport_unsupported.dart'
    if (dart.library.ffi) 'transport_ffi.dart'
    if (dart.library.js_interop) 'transport_web.dart';

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

/// Async facade over the rclone engine, native (FFI) or in the browser (WebAssembly).
class Rclone {
  Rclone._(this._transport);

  final RcloneTransport _transport;

  /// Starts the native library with its config file at [configPath] (an
  /// encrypted rclone.conf once a config password is set).
  static Future<Rclone> start({required String configPath, String? libraryPath}) async {
    final transport = createTransport(libraryPath: libraryPath);
    final error = await transport.initialize(configPath);
    if (error != null) throw RcloneException('initialize', 500, error);
    return Rclone._(transport);
  }

  /// Starts the browser engine. Its config lives in memory: [onConfigSaved]
  /// gets it, encrypted with the config password, every time rclone saves it.
  static Future<Rclone> startInBrowser({required void Function(String encryptedConf) onConfigSaved}) async {
    final transport = createTransport();
    final error = await transport.initializeInMemory(onConfigSaved);
    if (error != null) throw RcloneException('initialize', 500, error);
    return Rclone._(transport);
  }

  /// Sets the key of the encrypted rclone.conf; throws if it can't decrypt the file on disk.
  Future<void> setConfigPassword(String password) async {
    final error = await _transport.setConfigPassword(password);
    if (error != null) throw RcloneException('setConfigPassword', 400, error);
  }

  /// Browser: unlocks [encryptedConf] (empty to start a new config) with [password].
  Future<void> unlock(String password, String encryptedConf) async {
    final error = await _transport.unlock(password, encryptedConf);
    if (error != null) throw RcloneException('unlock', 400, error);
  }

  /// Calls rc [method] (https://rclone.org/rc/) and returns its JSON reply.
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    final reply = await _transport.rpc(method, jsonEncode(params));
    final decoded = reply.output.isEmpty ? <String, dynamic>{} : jsonDecode(reply.output) as Map<String, dynamic>;
    if (reply.status != 200) {
      throw RcloneException(method, reply.status, decoded['error']?.toString() ?? reply.output);
    }
    return decoded;
  }

  static var _nextStatsGroup = 0;

  /// Runs a long rc [method] and reports transfer progress.
  ///
  /// The call returns the moment rclone finishes; [onProgress] polls
  /// `core/stats` for the call's stats group meanwhile.
  Future<Map<String, dynamic>> runJob(
    String method,
    Map<String, dynamic> params, {
    void Function(JobProgress progress)? onProgress,
  }) {
    final group = 'cryptdrive/${_nextStatsGroup++}';
    return _reportProgress(call(method, {...params, '_group': group}), group, onProgress);
  }

  /// Browser: encrypts and writes [data] to [remote] inside [fs] (e.g. "vault:").
  Future<void> putFile(String fs, String remote, Uint8List data, {void Function(JobProgress progress)? onProgress}) {
    final group = 'cryptdrive/${_nextStatsGroup++}';
    return _reportProgress(_wrap('putFile', _transport.putFile(fs, remote, data, group)), group, onProgress);
  }

  /// Browser: reads and decrypts [count] bytes of [remote] from [offset]; a negative count reads to the end.
  Future<Uint8List> readFile(String fs, String remote, {int offset = 0, int count = -1}) =>
      _wrap('readFile', _transport.readFile(fs, remote, offset, count));

  Future<T> _wrap<T>(String method, Future<T> operation) async {
    try {
      return await operation;
    } on UnsupportedError {
      rethrow;
    } catch (error) {
      throw RcloneException(method, 500, '$error'.replaceFirst(RegExp(r'^(Error|JavaScriptError): '), ''));
    }
  }

  Future<T> _reportProgress<T>(Future<T> result, String group, void Function(JobProgress)? onProgress) async {
    if (onProgress == null) return result;
    var finished = false;
    result.whenComplete(() => finished = true).ignore();
    while (!finished) {
      await Future.any([result, Future<void>.delayed(const Duration(milliseconds: 200))]).catchError((_) => null);
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
  Future<void> shutdown() => _transport.finalize();
}
