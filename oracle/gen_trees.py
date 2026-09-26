import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import boot
from paths import HERE, FIXTURES, ensure_sandbox

SANDBOX = ensure_sandbox()
from corpus_custom import CUSTOM
docs = [{"name": "custom: " + n, "doc": d} for n, d in CUSTOM]
docs += json.load(open(HERE / "corpus-spec.json"))
for p in sorted(SANDBOX.rglob("*.md")):
    if p.name != "__oracle.md":
        docs.append({"name": "sample: " + str(p.relative_to(SANDBOX)), "doc": p.read_text()})
o = boot(height=4000)
out, t0 = [], time.time()
for i, d in enumerate(docs):
    o.js(f"__flo.setDoc({json.dumps(d['doc'])}, 0)")
    tree = o.js("__flo.dumpTree()")
    full = tree and tree[0][2] >= len(d["doc"].encode('utf-16-le')) // 2
    out.append({"name": d["name"], "doc": d["doc"], "tree": tree, "complete": bool(full)})
    if i % 100 == 0: print(i, round(time.time() - t0, 1), flush=True)
json.dump(out, open(os.environ.get("TREES_OUT", FIXTURES / "trees.json"), "w"))
print("wrote", len(out), "incomplete:", [x["name"] for x in out if not x["complete"]][:10])
print("console:", o.console[-5:])
o.close()
