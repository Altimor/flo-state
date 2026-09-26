"""Navigation geometry fixtures: CM moveToLineBoundary / moveVertically at
sampled carets, resolved by the web app's real layout (1400x900 window)."""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import boot
from paths import HERE, FIXTURES, ensure_sandbox

SANDBOX = ensure_sandbox()
from corpus_custom import CUSTOM

def u16(s): return len(s.encode("utf-16-le")) // 2

docs = [("custom: " + n, d.replace("\r\n", "\n").replace("\r", "\n")) for n, d in CUSTOM if len(d) < 3000]
for p in sorted(SANDBOX.rglob("*.md")):
    if p.name != "__oracle.md":
        docs.append(("sample: " + str(p.relative_to(SANDBOX)), p.read_text().replace("\r\n", "\n")))
limit = int(sys.argv[1]) if len(sys.argv) > 1 else 10**9

PROBE = """(async () => {
  const v = __flo.view();
  v.dispatch({ selection: { anchor: %d }, scrollIntoView: true });
  await __flo.settle();
  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  const r = v.state.selection.main;
  const f = s => [s.head, s.assoc, s.goalColumn ?? null];
  return { pos: r.head, lbF: f(v.moveToLineBoundary(r, true)), lbB: f(v.moveToLineBoundary(r, false)),
           vD: f(v.moveVertically(r, true)), vU: f(v.moveVertically(r, false)) };
})()"""

o = boot(port=9346, height=900)
out, t0 = [], time.time()
for name, doc in docs[:limit]:
    lines = doc.split("\n")
    starts, acc = [], 0
    for l in lines:
        starts.append(acc); acc += u16(l) + 1
    pos = set()
    step = max(1, len(lines) // 25)
    for li in range(0, len(lines), step):
        L = u16(lines[li])
        for k in {0, L // 3, (2 * L) // 3, L}:
            pos.add(starts[li] + k)
    o.js(f"__flo.setDoc({json.dumps(doc)}, 0)")
    probes = []
    for p in sorted(pos):
        try:
            if o.js("__flo.docText()") != doc:
                o.js(f"__flo.setDoc({json.dumps(doc)}, 0)")
            r = o.js(PROBE % p)
        except RuntimeError as e:
            print("  skip", p, str(e)[:120], flush=True)
            continue
        r["want"] = p
        probes.append(r)
    out.append({"name": name, "doc": doc, "probes": probes})
    print(len(out), name, len(probes), round(time.time() - t0), flush=True)
json.dump(out, open(os.environ.get("BOUNDS_OUT", FIXTURES / "bounds.json"), "w"))
print("wrote", len(out))
o.close()
