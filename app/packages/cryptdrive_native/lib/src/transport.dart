import 'dart:typed_data';

/// How [Rclone] reaches the engine: the native library through FFI, or the
/// WebAssembly build in a browser worker. Calls a transport can't do throw
/// [UnsupportedError].
abstract interface class RcloneTransport {
  /// Native: rclone keeps its config in the file at [configPath].
  Future<String?> initialize(String configPath);

  /// Native: key of the encrypted config file. Returns an error message, or null.
  Future<String?> setConfigPassword(String password);

  /// Browser: rclone keeps its config in memory and hands it out encrypted on every save.
  Future<String?> initializeInMemory(void Function(String encryptedConf) onConfigSaved);

  /// Browser: sets the config password and loads [encryptedConf] (empty for a new config).
  Future<String?> unlock(String password, String encryptedConf);

  Future<({String output, int status})> rpc(String method, String input);

  /// Browser: writes [data] to [remote] inside [fs].
  Future<void> putFile(String fs, String remote, Uint8List data, String statsGroup);

  /// Browser: reads [count] bytes from [offset]; a negative count reads to the end.
  Future<Uint8List> readFile(String fs, String remote, int offset, int count);

  Future<void> finalize();
}
