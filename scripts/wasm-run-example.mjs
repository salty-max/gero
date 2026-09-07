// Build and run one example through `gero.wasm`, printing whatever the
// program printed.
//
// This is the host half of the runtime gate: `wasm32` is otherwise only
// ever compile-checked, and every runtime test gero has runs natively.
// Node stands in for a browser — same engine family, same boundary.
//
// Usage: node scripts/wasm-run-example.mjs <gero.wasm> <entry file>
// Exit:  0 on a clean run to `hlt`; 1 on any build or run failure.

import { readFile, readdir } from 'node:fs/promises';
import { dirname, basename, join, extname } from 'node:path';

/// Instructions to retire per slice, and overall before calling it a hang.
const SLICE = 100_000;
const CEILING = 50_000_000;

const [wasmPath, entryPath] = process.argv.slice(2);
if (!wasmPath || !entryPath) {
  console.error('usage: wasm-run-example.mjs <gero.wasm> <entry file>');
  process.exit(1);
}

const { instance: { exports: e } } = await WebAssembly.instantiate(await readFile(wasmPath), {});
const enc = new TextEncoder(), dec = new TextDecoder();

const die = (msg) => { console.error(`${basename(entryPath)}: ${msg}`); process.exit(1); };

if (e.gero_init(0) !== 0) die('gero_init failed');
const BASE = e.gero_arena_base();

/// Copy bytes into the module's input region.
const put = (data) => {
  const bytes = typeof data === 'string' ? enc.encode(data) : data;
  const ptr = e.gero_alloc(bytes.length);
  if (ptr === 0 && bytes.length > 0) die('arena exhausted writing input');
  new Uint8Array(e.memory.buffer, BASE + ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
};

/// Decode the five-u32 Result at `ptr`.
const read = (ptr) => {
  const view = new DataView(e.memory.buffer);
  const at = (i) => view.getUint32(ptr + i * 4, true);
  const grab = (p, n) => (n ? new Uint8Array(e.memory.buffer, BASE + p, n).slice() : new Uint8Array(0));
  return { status: at(0), payload: grab(at(1), at(2)), diagnostics: dec.decode(grab(at(3), at(4))) };
};

// The whole directory becomes the virtual file set, so `include` and
// `use` resolve exactly as they do on disk.
const dir = dirname(entryPath);
for (const name of await readdir(dir)) {
  if (!['.gas', '.gr'].includes(extname(name))) continue;
  const [np, nl] = put(name);
  const [sp, sl] = put(await readFile(join(dir, name), 'utf8'));
  if (e.gero_file_put(np, nl, sp, sl) !== 0) die(`could not add ${name} to the file set`);
}

const entry = basename(entryPath);
const isAsm = extname(entry) === '.gas';
const [ep, el] = put(entry);
const built = read(isAsm ? e.gero_assemble(ep, el) : e.gero_compile(ep, el));
if (built.status !== 0) die(`build failed: ${built.diagnostics || `status ${built.status}`}`);

const vm = e.gero_vm_create();
if (vm === 0) die('could not create a VM session');
const [ip, il] = put(built.payload);
const loaded = read(e.gero_vm_load(vm, ip, il));
if (loaded.status !== 0) die(`load failed: ${loaded.diagnostics || `status ${loaded.status}`}`);

const REASONS = ['budget', 'halted', 'breakpoint', 'faulted', 'not loaded'];
let output = '', retired = 0;
for (;;) {
  const r = read(e.gero_vm_step(vm, SLICE));
  if (r.status !== 0) die(`step failed with status ${r.status}`);
  const view = new DataView(r.payload.buffer);
  const [reason, pc, fault, steps] = [0, 1, 2, 3].map((i) => view.getUint32(i * 4, true));
  retired += steps;

  // Drain every slice, so a chatty program cannot outrun the buffer.
  const out = read(e.gero_vm_take_output(vm));
  output += dec.decode(out.payload);

  if (reason === 1) break;
  if (reason !== 0) die(`stopped: ${REASONS[reason]}${reason === 3 ? ` (vector 0x${fault.toString(16).padStart(2, '0')})` : ''} at ip=0x${pc.toString(16).padStart(4, '0')}`);
  if (retired > CEILING) die(`did not halt within ${CEILING} instructions`);
}

process.stdout.write(output);
