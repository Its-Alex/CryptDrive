import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Holds the key of the encrypted rclone.conf in the OS keystore.
abstract class SecretStore {
  Future<String?> readConfigPassword();
  Future<void> writeConfigPassword(String password);
  Future<void> deleteConfigPassword();
}

class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  static const _configPasswordKey = 'rclone_config_password';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> readConfigPassword() => _storage.read(key: _configPasswordKey);

  @override
  Future<void> writeConfigPassword(String password) => _storage.write(key: _configPasswordKey, value: password);

  @override
  Future<void> deleteConfigPassword() => _storage.delete(key: _configPasswordKey);
}

class InMemorySecretStore implements SecretStore {
  String? _password;

  @override
  Future<String?> readConfigPassword() async => _password;

  @override
  Future<void> writeConfigPassword(String password) async => _password = password;

  @override
  Future<void> deleteConfigPassword() async => _password = null;
}

String generateConfigPassword() {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
}
