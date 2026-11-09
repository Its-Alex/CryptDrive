import 'dart:io';

import 'package:path/path.dart' as p;

/// Small app-private texts (encrypted browser config, recent files list).
abstract interface class AppStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FileAppStore implements AppStore {
  FileAppStore(this.directory);

  final Directory directory;

  File _file(String key) => File(p.join(directory.path, key));

  @override
  Future<String?> read(String key) async {
    final file = _file(key);
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<void> write(String key, String value) async {
    await directory.create(recursive: true);
    await _file(key).writeAsString(value);
  }

  @override
  Future<void> delete(String key) async {
    final file = _file(key);
    if (await file.exists()) await file.delete();
  }
}

class MemoryAppStore implements AppStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}
