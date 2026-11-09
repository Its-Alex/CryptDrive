// Runs the rclone engine (cryptdrive.wasm) off the UI thread: encryption is CPU-bound.
importScripts('wasm_exec.js');

const go = new Go();
// Without HOME, rclone logs that it can't find a config directory at startup.
go.env = { HOME: '/' };
const engine = WebAssembly.instantiateStreaming(fetch('cryptdrive.wasm'), go.importObject).then(({ instance }) => {
  go.run(instance);
  return self.cryptdriveGo;
});

const operations = {
  initialize: (cryptdrive) => cryptdrive.initialize((encryptedConf) => postMessage({ event: 'configSaved', encryptedConf })),
  unlock: (cryptdrive, password, encryptedConf) => cryptdrive.unlock(password, encryptedConf),
  rpc: (cryptdrive, method, input) => cryptdrive.rpc(method, input),
  putFile: (cryptdrive, fs, remote, data, statsGroup) => cryptdrive.putFile(fs, remote, data, statsGroup),
  readFile: (cryptdrive, fs, remote, offset, count) => cryptdrive.readFile(fs, remote, offset, count),
  finalize: (cryptdrive) => cryptdrive.finalize(),
};

self.onmessage = async ({ data: { id, op, args } }) => {
  try {
    const result = await operations[op](await engine, ...args);
    postMessage({ id, result }, result instanceof Uint8Array ? [result.buffer] : []);
  } catch (error) {
    postMessage({ id, error: String(error && error.message ? error.message : error) });
  }
};
