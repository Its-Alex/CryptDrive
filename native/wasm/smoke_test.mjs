// Round-trip through the browser engine under Node: same wasm, same fake file system as a browser.
// Usage: node native/wasm/smoke_test.mjs app/web/cryptdrive
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import assert from 'node:assert/strict';
import vm from 'node:vm';

const dir = process.argv[2];
vm.runInThisContext(await readFile(join(dir, 'wasm_exec.js'), 'utf8'));
const go = new globalThis.Go();
go.env = { HOME: '/' };
const { instance } = await WebAssembly.instantiate(await readFile(join(dir, 'cryptdrive.wasm')), go.importObject);
go.run(instance);
const engine = globalThis.cryptdriveGo;

let savedConf = '';
assert.equal(engine.initialize((text) => { savedConf = text; }), null);
assert.equal(engine.unlock('browser password', ''), null);

async function rpc(method, params = {}) {
  const { output, status } = await engine.rpc(method, JSON.stringify(params));
  assert.equal(status, 200, `${method}: ${output}`);
  return JSON.parse(output);
}

await rpc('config/create', { name: 'memorystore', type: 'memory', parameters: {}, opt: { nonInteractive: true } });
await rpc('config/create', {
  name: 'vault', type: 'crypt',
  parameters: { remote: 'memorystore:CryptDrive', password: 'vault password' },
  opt: { nonInteractive: true, obscure: true },
});
assert.match(savedConf, /RCLONE_ENCRYPT_V0:/);
assert.doesNotMatch(savedConf, /\[vault\]/);

const photo = new Uint8Array(5 * 1024 * 1024).map((_, i) => i % 251);
await engine.putFile('vault:', 'Photos/beach.jpg', photo, 'smoke');
const listing = await rpc('operations/list', { fs: 'vault:', remote: 'Photos' });
assert.equal(listing.list[0].Name, 'beach.jpg');
assert.equal(listing.list[0].Size, photo.length);

const stored = await rpc('operations/list', { fs: 'memorystore:CryptDrive', remote: '', opt: { recurse: true } });
assert.ok(stored.list.every((item) => !item.Name.includes('beach') && !item.Name.includes('Photos')));

const head = await engine.readFile('vault:', 'Photos/beach.jpg', 0, 1024);
assert.deepEqual(head, photo.subarray(0, 1024));
const whole = await engine.readFile('vault:', 'Photos/beach.jpg', 0, -1);
assert.deepEqual(whole, photo);

const reopenedConf = savedConf;
assert.match(engine.unlock('wrong password', reopenedConf), /wrong config password/);
assert.equal(engine.unlock('browser password', reopenedConf), null);
assert.ok((await rpc('config/listremotes')).remotes.includes('vault'));

console.log('wasm engine round-trip: ok');
process.exit(0);
