import 'dart:isolate';
import 'dart:typed_data';

import 'bindings.dart';
import 'transport.dart';

RcloneTransport createTransport({String? libraryPath}) => FfiTransport(libraryPath);

/// Every call runs on a short-lived isolate so the UI isolate never blocks on network or crypto.
class FfiTransport implements RcloneTransport {
  FfiTransport(this._libraryPath);

  final String? _libraryPath;

  Future<T> _run<T>(T Function(CryptDriveBindings bindings) body) {
    final libraryPath = _libraryPath;
    return Isolate.run(() => body(CryptDriveBindings(openCryptDriveLibrary(libraryPath))));
  }

  @override
  Future<String?> initialize(String configPath) => _run((bindings) => bindings.initialize(configPath));

  @override
  Future<String?> setConfigPassword(String password) => _run((bindings) => bindings.setConfigPassword(password));

  @override
  Future<({String output, int status})> rpc(String method, String input) =>
      _run((bindings) => bindings.rpc(method, input));

  @override
  Future<void> finalize() => _run((bindings) => bindings.finalize());

  @override
  Future<String?> initializeInMemory(void Function(String encryptedConf) onConfigSaved) =>
      throw UnsupportedError('The native library keeps its config in a file');

  @override
  Future<String?> unlock(String password, String encryptedConf) =>
      throw UnsupportedError('The native library keeps its config in a file');

  @override
  Future<void> putFile(String fs, String remote, Uint8List data, String statsGroup) =>
      throw UnsupportedError('Native apps upload local files with operations/copyfile');

  @override
  Future<Uint8List> readFile(String fs, String remote, int offset, int count) =>
      throw UnsupportedError('Native apps download to local files with operations/copyfile');
}
