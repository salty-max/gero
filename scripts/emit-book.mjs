// Pack The Gero Book into the wasm artifact's asset set.
//
// The lab renders these chapters; it does not vendor them. A browser
// cannot list `docs/book/` over HTTP, hence the manifest — the same
// reason `samples.json` exists (docs/gero-lab.md §9, §10).
//
// Usage: node scripts/emit-book.mjs <out dir>

import { readdir, readFile, mkdir, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";

const out = process.argv[2] ?? "zig-out/book";
const root = "docs/book";

const files = (await readdir(root))
  .filter((n) => n.endsWith(".md"))
  .sort((a, b) => {
    if (a === "README.md") return -1;
    if (b === "README.md") return 1;
    return a.localeCompare(b);
  });

const chapters = [];
for (const name of files) {
  const body = await readFile(join(root, name), "utf8");
  const heading = body.match(/^#\s+(.+)$/m)?.[1]?.trim() ?? basename(name, ".md");
  chapters.push({
    slug: name === "README.md" ? "" : basename(name, ".md"),
    title: heading,
    file: name,
    body,
  });
}

await mkdir(out, { recursive: true });
await writeFile(
  join(out, "book.json"),
  JSON.stringify({ version: 1, title: "The Gero Book", chapters }, null, 2),
);
console.log(`book: ${chapters.length} chapters written to ${join(out, "book.json")}`);
