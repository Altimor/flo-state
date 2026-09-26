// Extract the @lezer/markdown spec tests (CommonMark + GFM examples) into
// corpus-spec.json. Needs a writer-computer checkout with node_modules
// installed: $WRITER_REPO, default ../writer-computer next to this repo.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = process.env.WRITER_REPO || path.resolve(here, "..", "..", "writer-computer");
const pnpm = path.join(repo, "node_modules", ".pnpm");
const pkg = fs.readdirSync(pnpm).filter((n) => n.startsWith("@lezer+markdown@")).sort().pop();
if (!pkg) throw new Error(`@lezer/markdown not found under ${pnpm} (set WRITER_REPO and run pnpm install there)`);
const d = path.join(pnpm, pkg, "node_modules", "@lezer", "markdown", "test") + path.sep;
const out = [];
for (const f of ["test-markdown.ts", "test-extension.ts"]) {
  const src = fs.readFileSync(d + f, "utf8");
  const re = /test\("([^"]+)",\s*(`(?:\\[\s\S]|\$\{|[^`\\])*`)/g;
  let m;
  while ((m = re.exec(src))) {
    let spec;
    try { spec = new Function("return " + m[2])(); } catch { continue; }
    let doc = "";
    for (let i = 0; i < spec.length; i++) {
      const ch = spec[i];
      if (ch === "{") { const n = /^(\w+):/.exec(spec.slice(i + 1)); if (n) { i += n[0].length; continue; } }
      if (ch === "}") continue;
      doc += ch;
    }
    out.push({ name: `${f}: ${m[1]}`, doc });
  }
}
fs.writeFileSync(path.join(here, "corpus-spec.json"), JSON.stringify(out));
console.log(out.length, "spec docs");
