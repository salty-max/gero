// Pack the books into the wasm artifact's asset set.
//
// The lab renders these chapters; it does not vendor them. A browser
// cannot list `docs/book/` over HTTP, hence the manifest — the same
// reason `samples.json` exists (docs/gero-lab.md §9, §10).
//
// Usage: node scripts/emit-book.mjs <out dir>

import { readdir, readFile, mkdir, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";

const out = process.argv[2] ?? "zig-out/book";

/** Both books, in reading order. `id` is what a reader's URL carries,
 *  and what a cross-book link in one book resolves against. */
const BOOKS = [
  { id: "book", root: "docs/book", title: "The Gero Book" },
  { id: "machine", root: "docs/machine", title: "The Gero Machine" },
];

async function pack({ id, root, title }) {
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
  return { id, title, chapters };
}

const books = [];
for (const b of BOOKS) books.push(await pack(b));

await mkdir(out, { recursive: true });
await writeFile(
  join(out, "books.json"),
  JSON.stringify({ version: 2, books }, null, 2),
);
const counts = books.map((b) => `${b.id}: ${b.chapters.length}`).join(", ");
console.log(`books: ${counts} written to ${join(out, "books.json")}`);
