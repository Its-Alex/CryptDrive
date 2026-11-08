import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class RcloneRPCResult extends Struct {
  external Pointer<Utf8> output;

  @Int()
  external int status;
}

typedef _InitializeNative = Pointer<Utf8> Function(Pointer<Utf8> configPath);
typedef _SetConfigPasswordNative = Pointer<Utf8> Function(Pointer<Utf8> password);
typedef _RpcNative = RcloneRPCResult Function(Pointer<Utf8> method, Pointer<Utf8> input);
typedef _FreeStringNative = Void Function(Pointer<Utf8> string);
typedef _FreeString = void Function(Pointer<Utf8> string);
typedef _FinalizeNative = Void Function();
typedef _Finalize = void Function();

/// Opens libcryptdrive; [libraryPath] overrides the platform default (tests).
DynamicLibrary openCryptDriveLibrary([String? libraryPath]) {
  final path = libraryPath ?? Platform.environment['CRYPTDRIVE_NATIVE_LIBRARY'];
  if (path != null && path.isNotEmpty) return DynamicLibrary.open(path);
  if (Platform.isIOS) return DynamicLibrary.process();
  if (Platform.isMacOS) {
    try {
      return DynamicLibrary.open('libcryptdrive.dylib');
    } on ArgumentError {
      return DynamicLibrary.process();
    }
  }
  if (Platform.isWindows) return DynamicLibrary.open('cryptdrive.dll');
  return DynamicLibrary.open('libcryptdrive.so');
}

/// Synchronous, direct mapping of the C API built from `native/`.
///
/// Every call blocks the calling isolate; use [Rclone] from UI code.
class CryptDriveBindings {
  CryptDriveBindings(DynamicLibrary library)
    : _initialize = library.lookupFunction<_InitializeNative, _InitializeNative>('CryptDriveInitialize'),
      _setConfigPassword = library.lookupFunction<_SetConfigPasswordNative, _SetConfigPasswordNative>(
        'CryptDriveSetConfigPassword',
      ),
      _rpc = library.lookupFunction<_RpcNative, _RpcNative>('RcloneRPC'),
      _freeString = library.lookupFunction<_FreeStringNative, _FreeString>('RcloneFreeString'),
      _finalize = library.lookupFunction<_FinalizeNative, _Finalize>('RcloneFinalize');

  final _InitializeNative _initialize;
  final _SetConfigPasswordNative _setConfigPassword;
  final _RpcNative _rpc;
  final _FreeString _freeString;
  final _Finalize _finalize;

  /// Returns an error message, or null on success.
  String? initialize(String configPath) => _withCString(configPath, (path) => _takeOptionalString(_initialize(path)));

  /// Returns an error message (e.g. wrong password), or null on success.
  String? setConfigPassword(String password) =>
      _withCString(password, (cPassword) => _takeOptionalString(_setConfigPassword(cPassword)));

  ({String output, int status}) rpc(String method, String inputJson) {
    return _withCString(method, (cMethod) {
      return _withCString(inputJson, (cInput) {
        final result = _rpc(cMethod, cInput);
        try {
          return (output: result.output.toDartString(), status: result.status);
        } finally {
          _freeString(result.output);
        }
      });
    });
  }

  void finalize() => _finalize();

  String? _takeOptionalString(Pointer<Utf8> pointer) {
    if (pointer == nullptr) return null;
    try {
      return pointer.toDartString();
    } finally {
      _freeString(pointer);
    }
  }

  static T _withCString<T>(String value, T Function(Pointer<Utf8>) body) {
    final pointer = value.toNativeUtf8();
    try {
      return body(pointer);
    } finally {
      malloc.free(pointer);
    }
  }
}
