import 'dart:js_interop';
import 'dart:typed_data';

import 'transport.dart';

RcloneTransport createTransport({String? libraryPath}) => WebTransport();

@JS('cryptdrive')
external _CryptDriveBridge? get _bridge;

/// window.cryptdrive, defined by web/cryptdrive/bridge.js.
extension type _CryptDriveBridge(JSObject _) implements JSObject {
  external JSPromise<JSAny?> invoke(String op, JSArray<JSAny?> args);
  external void onConfigSaved(JSFunction listener);
}

extension type _RpcReply(JSObject _) implements JSObject {
  external String get output;
  external int get status;
}

/// Talks to cryptdrive.wasm running in a Web Worker.
class WebTransport implements RcloneTransport {
  _CryptDriveBridge get _engine {
    final bridge = _bridge;
    if (bridge == null) throw StateError('cryptdrive/bridge.js is not loaded');
    return bridge;
  }

  Future<JSAny?> _invoke(String op, List<JSAny?> args) => _engine.invoke(op, args.toJS).toDart;

  @override
  Future<String?> initializeInMemory(void Function(String encryptedConf) onConfigSaved) async {
    _engine.onConfigSaved(((JSString encryptedConf) => onConfigSaved(encryptedConf.toDart)).toJS);
    return (await _invoke('initialize', []) as JSString?)?.toDart;
  }

  @override
  Future<String?> unlock(String password, String encryptedConf) async =>
      (await _invoke('unlock', [password.toJS, encryptedConf.toJS]) as JSString?)?.toDart;

  @override
  Future<({String output, int status})> rpc(String method, String input) async {
    final reply = await _invoke('rpc', [method.toJS, input.toJS]) as _RpcReply;
    return (output: reply.output, status: reply.status);
  }

  @override
  Future<void> putFile(String fs, String remote, Uint8List data, String statsGroup) async {
    // The buffer is transferred to the worker: send a copy so the caller's bytes stay usable,
    // whatever memory toJS hands back (a clone, or a view on this side's storage).
    await _invoke('putFile', [fs.toJS, remote.toJS, Uint8List.fromList(data).toJS, statsGroup.toJS]);
  }

  @override
  Future<Uint8List> readFile(String fs, String remote, int offset, int count) async =>
      (await _invoke('readFile', [fs.toJS, remote.toJS, offset.toJS, count.toJS]) as JSUint8Array).toDart;

  @override
  Future<void> finalize() async {
    await _invoke('finalize', []);
  }

  @override
  Future<String?> initialize(String configPath) =>
      throw UnsupportedError('The browser engine keeps its config in memory');

  @override
  Future<String?> setConfigPassword(String password) =>
      throw UnsupportedError('The browser engine is unlocked with unlock()');
}
