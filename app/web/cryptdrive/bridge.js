// window.cryptdrive: promise-based access to the rclone engine running in worker.js.
(() => {
  const worker = new Worker(new URL('worker.js', document.currentScript.src));
  const pending = new Map();
  const configListeners = [];
  let nextId = 0;
  let stopped = null;

  // A trap inside the wasm module kills the worker without settling anything, and every
  // call then waits forever: the app looks idle instead of saying the engine is gone.
  const stop = (reason) => {
    stopped = `CryptDrive's browser engine stopped: ${reason}`;
    const error = new Error(stopped);
    for (const call of pending.values()) call.reject(error);
    pending.clear();
  };
  worker.onerror = (event) => stop(event.message || 'unknown error');
  worker.onmessageerror = () => stop('a message from the engine could not be decoded');

  worker.onmessage = ({ data }) => {
    if (data.event === 'configSaved') {
      configListeners.forEach((listener) => listener(data.encryptedConf));
      return;
    }
    const call = pending.get(data.id);
    pending.delete(data.id);
    if (call === undefined) return;
    if ('error' in data) call.reject(new Error(data.error));
    else call.resolve(data.result === undefined ? null : data.result);
  };

  window.cryptdrive = {
    invoke(op, args) {
      if (stopped !== null) return Promise.reject(new Error(stopped));
      return new Promise((resolve, reject) => {
        const id = nextId++;
        pending.set(id, { resolve, reject });
        const transfer = args.filter((arg) => arg instanceof Uint8Array).map((arg) => arg.buffer);
        worker.postMessage({ id, op, args }, transfer);
      });
    },
    onConfigSaved(listener) {
      configListeners.push(listener);
    },
  };
})();
