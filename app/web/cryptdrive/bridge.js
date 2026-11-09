// window.cryptdrive: promise-based access to the rclone engine running in worker.js.
(() => {
  const worker = new Worker(new URL('worker.js', document.currentScript.src));
  const pending = new Map();
  const configListeners = [];
  let nextId = 0;

  worker.onmessage = ({ data }) => {
    if (data.event === 'configSaved') {
      configListeners.forEach((listener) => listener(data.encryptedConf));
      return;
    }
    const call = pending.get(data.id);
    pending.delete(data.id);
    if ('error' in data) call.reject(new Error(data.error));
    else call.resolve(data.result === undefined ? null : data.result);
  };

  window.cryptdrive = {
    invoke(op, args) {
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
