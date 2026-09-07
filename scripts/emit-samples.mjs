// Collect the example corpus into the wasm artifact's sample set.
//
// `docs/gero-lab.md` §9 draws the lab's samples from this repository's
// examples so they cannot drift from what CI proves works — and §10
// puts the module's release in charge of carrying them, so the
// application never keeps a copy of its own to fall out of date.
//
// A browser cannot list a directory over HTTP, hence the manifest.
//
// Usage: node scripts/emit-samples.mjs <out dir>

import { readdir, readFile, mkdir, writeFile, cp } from 'node:fs/promises';
import { join, extname, basename } from 'node:path';

const out = process.argv[2] ?? 'zig-out/samples';
const roots = [
  { dir: 'examples/asm', lang: 'gas', ext: '.gas' },
  { dir: 'examples/lang', lang: 'gr', ext: '.gr' },
];

/// Every directory under `root` that holds sources, root included —
/// `examples/asm/banks` is one sample split across three files.
async function sampleDirs(root) {
  const dirs = [root];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (entry.isDirectory()) dirs.push(join(root, entry.name));
  }
  return dirs;
}

const samples = [];
for (const { dir: root, lang, ext } of roots) {
  for (const dir of await sampleDirs(root)) {
    const names = (await readdir(dir)).filter((n) => extname(n) === ext);
    if (names.length === 0) continue;

    // An entry point is a source with a golden `.expected` beside it.
    const entries = [];
    for (const name of names) {
      const expected = join(dir, `${basename(name, ext)}.expected`);
      if (await readFile(expected).then(() => true, () => false)) entries.push(name);
    }
    if (entries.length === 0) continue;

    // A directory with one entry point is a single multi-file sample —
    // `examples/asm/banks` is one program in three files — and takes
    // the directory's name. A directory with several is a flat corpus
    // where each file stands alone; bundling its siblings would ship
    // every example inside every other one.
    if (entries.length === 1 && dir !== root) {
      const files = {};
      for (const sibling of names) files[sibling] = await readFile(join(dir, sibling), 'utf8');
      samples.push({ name: basename(dir), lang, entry: entries[0], files });
    } else {
      for (const name of entries) {
        samples.push({
          name: basename(name, ext),
          lang,
          entry: name,
          files: { [name]: await readFile(join(dir, name), 'utf8') },
        });
      }
    }
  }
}

samples.sort((a, b) => (a.lang + a.name).localeCompare(b.lang + b.name));
await mkdir(out, { recursive: true });
await writeFile(join(out, 'samples.json'), JSON.stringify({ version: 1, samples }, null, 2));
console.log(`samples: ${samples.length} written to ${join(out, 'samples.json')}`);
