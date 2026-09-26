"""Generate editing-behavior fixtures: (doc, selection, keys) -> (doc, selection)."""
import json
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import boot
from paths import FIXTURES, ensure_sandbox
from keys import press, type_text, split_marked

C = []  # (name, marked_doc, keys, tags)


def add(name, marked, keys, tags=()):
    C.append((name, marked, keys if isinstance(keys, list) else [keys], list(tags)))


# ---- Lists: Enter / Backspace / Tab / Shift-Tab / Mod-Backspace ----------------
LIST_LINES = ["- foo", "* foo", "+ foo", "  - foo", "    * foo", "- [ ] task", "- [x] done",
              "  * [X] nested", "1. one", "2) two", "  3. three", "- ", "  - ", "- [ ] ",
              "-", "-  wide", "-\ttab", "> quote", "> - quoted item", "10. ten"]
for i, line in enumerate(LIST_LINES):
    L = len(line)
    for pos in sorted({0, min(2, L), L // 2, L}):
        m = line[:pos] + "‸" + line[pos:]
        for k in ["Enter", "Backspace", "Tab", "Shift-Tab", "Mod-Backspace", "Delete"]:
            add(f"list[{i}] pos{pos} {k}", m, k, ["list"])
        add(f"list[{i}] pos{pos} in-doc Enter", "- a\n" + m + "\n- z", "Enter", ["list"])
        add(f"list[{i}] pos{pos} in-doc Tab", "- a\n" + m + "\n- z", "Tab", ["list"])

for base in ["- a\n- b\n- c‸", "1. a\n2. b‸\n3. c", "1. a‸\n2. b\n3. c", "- a\n  - b‸", "- a\n\n- b‸",
             "-  a\n- b‸", "-   a\n- ‸b", "* a\n    * b\n- ‸c", "- a\n  - b\n    - c‸"]:
    for k in ["Enter", "Tab", "Shift-Tab", "Backspace", ["Enter", "Enter"], ["Tab", "Tab"],
              ["Enter", "t:x"], ["Enter", "Tab", "t:y"], ["Enter", "Backspace"]]:
        add(f"list ctx {base!r} {k}", base, k, ["list"])

add("list sel indent", "- a\n«- b\n- c»", "Tab", ["list"])
add("list sel outdent", "- a\n«  - b\n  - c»", "Shift-Tab", ["list"])
add("list type after marker", "- ‸", ["t:hello", "Enter", "t:world"], ["list"])
add("task continue", "- [x] done‸", ["Enter", "t:next"], ["list"])
add("ordered continue renumber", "1. a‸\n2. b\n3. c", ["Enter", "t:new"], ["list"])
add("quote continue", "> hello‸", ["Enter", "t:there"], ["list"])
add("quote empty exit", "> hello\n> ‸", "Enter", ["list"])

# ---- Formatting chords -----------------------------------------------------------
FMT = ["Mod-b", "Mod-i", "Mod-Shift-x", "Mod-e", "Mod-Shift-8", "Mod-Shift-7",
       "Mod-Shift-.", "Mod-Shift-Enter", "Mod-Alt-1", "Mod-Alt-2", "Mod-Alt-3", "Mod-Alt-6", "Mod-Alt-0"]
FMT_DOCS = ["hel‸lo world", "‸", "«hello» world", "«hello world»", "**bo‸ld**", "*it‸al*", "***bo‸th***",
            "«**bold**»", "«*it*»", "«***x***»", "~~st‸rike~~", "`co‸de`", "- «buy milk   »",
            "«- one\n- two»", "«line one\nline two»", "## Hea‸ding", "# «Title»", "«a\n\nb»",
            "> «quoted»", "1. «first»", "- [ ] «task»", "foo ‸ bar", "a‸", "word‸", "‸word",
            "«  indented  »", "snake_ca‸se", "«**a** b»", "x «y» z"]
for d in FMT_DOCS:
    for k in FMT:
        add(f"fmt {d!r} {k}", d, k, ["format"])
for d in ["hel‸lo", "«hello»", "**b‸**"]:
    add(f"fmt toggle twice {d!r}", d, ["Mod-b", "Mod-b"], ["format"])
    add(f"fmt bold then italic {d!r}", d, ["Mod-b", "Mod-i"], ["format"])

# ---- Input handlers: space-outside-emphasis, close-marker-after-space, ~ ------------
for d, t in [("**bold‸**", " "), ("*it‸*", " "), ("~~s‸~~", " "), ("`c‸`", " "), ("***b‸***", " "),
             ("2 *‸ 3", " "), ("**this ‸", "**"), ("*this ‸", "*"), ("~~this ‸", "~~"), ("`this ‸", "`"),
             ("**this ‸", "*"), ("2 * 3 ‸", "*"), ("hello ‸", "*"), ("**a** **b ‸", "**"),
             ("«text»", "~"), ("«line1\nline2»", "~"), ("- «item»", "~"), ("‸", "~"), ("a‸", "~~"),
             ("we're‸", " "), ("don‸", "'t "), ("[[wi‸", "ki]]"), (":smi‸", "le: "), ("a -‸", "- b"),
             ("‸", "# Title\n\n- one\n- two\n\ntext **bold** end"), ("--‸", "-")]:
    add(f"input {d!r} +{t!r}", d, ["t:" + t], ["input"])

# ---- Headings: selection guard / arrows ---------------------------------------------
for d in ["## Foo‸", "## F‸oo", "## ‸Foo", "prev\n## ‸Foo", "prev\n### «Foo»", "# ‸"]:
    for k in ["Home", "Left", "Shift-Left", "Mod-Left", "Up", "Down", "Backspace", "End", "Enter"]:
        add(f"heading {d!r} {k}", d, k, ["heading"])

# ---- Navigation / default keymap -----------------------------------------------------
NAV_DOC = "# Title\n\nFirst line with **bold** words\n- item one\n  - nested two\n\nlast ‸line here"
for k in ["Left", "Right", "Alt-Left", "Alt-Right", "Mod-Left", "Mod-Right", "Shift-Left", "Shift-Alt-Left",
          "Home", "End", "Alt-Backspace", "Mod-Backspace", "Mod-a", "Mod-z", "Alt-Up", "Alt-Down",
          "Shift-Alt-Up", "Mod-Shift-k", "Mod-Enter", "Mod-]", "Mod-[", "Mod-d"]:
    add(f"nav {k}", NAV_DOC, k, ["nav"])
for pos_doc in ["- ‸item", "- i‸tem", "  - ‸nested", "- [ ] ‸task", "**‸bold**", "[li‸nk](url)"]:
    for k in ["Left", "Right", "Shift-Left", "Alt-Left", "Backspace"]:
        add(f"atomic {pos_doc!r} {k}", pos_doc, k, ["atomic"])

# ---- Undo ----------------------------------------------------------------------------
add("undo typing", "abc‸", ["t:def", "Mod-z"], ["undo"])
add("undo enter list", "- a‸", ["Enter", "Mod-z"], ["undo"])
add("redo", "abc‸", ["t:x", "Mod-z", "Mod-Shift-z"], ["undo"])

# ---- Fuzz: sample workspace text, random caret/selection, random key sequences ---------
rng = random.Random(1234)
pool_lines = []
for p in sorted(ensure_sandbox().rglob("*.md")):
    if p.name != "__oracle.md":
        pool_lines += [l for l in p.read_text().splitlines()]
FUZZ_KEYS = ["Enter", "Backspace", "Tab", "Shift-Tab", "Mod-Backspace", "Mod-b", "Mod-i", "Mod-Shift-x",
             "Left", "Right", "Delete", "t:x", "t: ", "t:*", "t:**", "t:~", "t:-", "t:`", "Alt-Backspace",
             "Home", "End", "Mod-Shift-8", "Mod-Alt-2"]
for i in range(900):
    start = rng.randrange(0, max(1, len(pool_lines) - 6))
    chunk = "\n".join(pool_lines[start:start + rng.randint(1, 6)])
    n = len(chunk)
    if rng.random() < 0.25 and n > 1:
        a, b = sorted(rng.sample(range(n + 1), 2))
        marked = chunk[:a] + "«" + chunk[a:b] + "»" + chunk[b:]
    else:
        a = rng.randint(0, n)
        marked = chunk[:a] + "‸" + chunk[a:]
    keys = [rng.choice(FUZZ_KEYS) for _ in range(rng.randint(1, 4))]
    add(f"fuzz{i}", marked, keys, ["fuzz"])


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    cases = [c for c in C if not only or only in c[3]]
    print(len(cases), "cases", flush=True)
    outpath = os.environ.get("KEYS_OUT") or (str(FIXTURES / "keys.jsonl") if not only else str(FIXTURES / f"keys-{only}.jsonl"))
    done = set()
    try:
        for line in open(outpath):
            done.add(json.loads(line)["name"])
    except FileNotFoundError:
        pass
    fout = open(outpath, "a")
    o = boot()
    out = []
    t0 = time.time()
    for i, (name, marked, keys, tags) in enumerate(cases):
        if name in done:
            continue
        if i and i % 250 == 0:
            o.close(); o = boot()
        doc, a, h = split_marked(marked)
        try:
            o.js(f"__flo.setDoc({json.dumps(doc)}, {a}, {h})")
            before = o.js("__flo.sel()")
            for k in keys:
                if k.startswith("t:"):
                    type_text(o, k[2:])
                else:
                    press(o, k)
                o.js("new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r())))")
            o.js("__flo.settle(1000)")
            rec = {"name": name, "tags": tags, "doc": doc, "sel": before, "keys": keys,
                   "outDoc": o.js("__flo.docText()"), "outSel": o.js("__flo.sel()")}
            fout.write(json.dumps(rec) + "\n"); fout.flush()
        except Exception as e:
            print("ERR", name, e, flush=True)
            o.close()
            o = boot()
        if i % 200 == 0:
            print(i, round(time.time() - t0), flush=True)
    print("done", "console:", o.console[-5:])
    o.close()


if __name__ == "__main__":
    main()
