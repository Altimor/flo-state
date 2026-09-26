"""Render fixtures: per-character computed style + geometry for doc x caret."""
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

ONLY = os.environ.get("ONLY")
if ONLY: docs = [(n, d) for n, d in docs if any(k in n for k in ONLY.split(","))]
o = boot(port=9345, height=3000, settings={"appearance.theme": "light"} if os.environ.get("LIGHT") else None)
out, t0 = [], time.time()
for name, doc in docs:
    lines = doc.split("\n")
    starts, acc = [], 0
    for l in lines:
        starts.append(acc); acc += u16(l) + 1
    carets = {("end", u16(doc))}
    # caret at start of doc, and at the end of up to 12 distinct lines (reveal behavior)
    carets.add(("start", 0))
    step = max(1, len(lines) // 12)
    for li in range(0, len(lines), step):
        carets.add((f"line{li}", starts[li] + u16(lines[li])))
    for tag, pos in sorted(carets, key=lambda x: x[1]):
        o.js(f"__flo.setDoc({json.dumps(doc)}, {pos})")
        if "```" in doc or "~~~" in doc or "$" in doc:
            # fenced-code languages and KaTeX load asynchronously: let them land
            time.sleep(0.25); o.js("__flo.settle()")
            if tag == "start":
                # the first state of a doc may still be loading its language: render it again once loaded
                time.sleep(0.8); o.js(f"__flo.setDoc({json.dumps(doc)}, {pos})"); time.sleep(0.25); o.js("__flo.settle()")
        r = o.js("__flo.render()")
        r["name"], r["caretTag"], r["caret"] = name, tag, pos
        out.append(r)
    print(len(out), name, round(time.time() - t0), flush=True)
json.dump(out, open(os.environ.get("RENDER_OUT", FIXTURES / "render.json"), "w"))
print("wrote", len(out), o.console[-3:])
o.close()
