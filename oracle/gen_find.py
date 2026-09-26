"""Record the web app's find/replace overlay behaviour (fixtures/find-wk.json).

Each case: doc + selection, then Mod-f (prefill), a query typed into the find
input, and a sequence of ops driven through the real overlay UI. After every
step we record doc, selection, counter text, the highlighted ranges and the
overview tick count.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cdp import boot

CASES = [
    # (name, doc, anchor, head, query|None (keep prefill), replace, ops)
    ("basic", "foo bar foo\nbaz FOO\n", 0, 0, "foo", "", ["next", "next", "next", "next", "prev", "prev"]),
    ("prefill", "hello world\nfoo bar foo\n", 12, 15, None, "", ["next", "next"]),
    ("prefill-multiline", "ab\ncd ab\n", 0, 4, None, "", []),
    ("overlap", "aaaa aaa", 0, 0, "aa", "", ["next", "next", "next", "next", "prev", "prev", "prev"]),
    ("case", "Straße STRASSE strasse", 0, 0, "strasse", "", ["next", "next", "next"]),
    ("unicode", "Café café CAFÉ ﬁle file", 0, 0, "café", "", ["next", "next", "next", "next"]),
    ("ligature", "ﬁle file FILE", 0, 0, "fi", "X", ["replace", "replace", "replace", "replace"]),
    ("emoji", "a😀b a😀b", 0, 0, "😀b", "", ["next", "next", "prev"]),
    ("escape-n", "one\ntwo\none\\ntwo", 0, 0, "one\\ntwo", "1\\t2", ["next", "next", "replace", "replace"]),
    ("replace-basic", "cat dog cat dog cat", 0, 0, "cat", "bird", ["replace", "replace", "replace", "replace", "replace"]),
    ("replace-contains", "aa aa", 0, 0, "a", "aa", ["replace", "replace", "replace", "replace"]),
    ("replace-all", "x1 X1 x1x1\nx1", 3, 3, "x1", "y", ["all"]),
    ("replace-all-empty", "remove me and remove me", 0, 0, "remove ", "", ["all"]),
    ("replace-all-none", "abc", 0, 0, "zz", "y", ["all"]),
    ("nomatch", "abc", 1, 1, "zz", "", ["next", "prev"]),
    ("wrap-at-end", "foo x foo", 9, 9, "foo", "", ["next", "prev", "prev"]),
    ("caret-inside", "abcdef abc", 2, 2, "abcd", "", ["next"]),
    ("modg", "k1 k2 k3", 0, 0, "k", "", ["modg", "modg", "modshiftg"]),
    ("selection-counter", "ab ab ab", 4, 4, "ab", "", []),
    ("markdown", "# Head **bold** text\n- item bold\n", 0, 0, "bold", "B", ["next", "replace", "all"]),
    ("empty-query", "abc", 0, 0, "", "", ["next", "all"]),
    ("dotted-i", "İstanbul istanbul ISTANBUL", 0, 0, "i", "", ["next", "next", "next", "next"]),
    ("sigma", "ΣΑΣ σας", 0, 0, "σας", "", ["next", "next"]),
]

KEYDOWN = """(sel, key, code, kc, shift, meta) => { const el = document.querySelector(sel);
  el.dispatchEvent(new KeyboardEvent('keydown', {key, code, keyCode: kc, shiftKey: shift, metaKey: meta, bubbles: true, cancelable: true})); return 1 }"""

SETVAL = """(sel, v) => { const el = document.querySelector(sel);
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  setter.call(el, v); el.dispatchEvent(new Event('input', {bubbles: true})); return 1 }"""

SNAP = """(() => { const v = __flo.view(); const s = v.state.selection.main;
  const card = document.querySelector('[data-search-overlay]');
  const counter = card ? [...card.querySelectorAll('span[aria-live]')].map(e => e.textContent)[0] ?? null : null;
  const hl = [...document.querySelectorAll('.cm-searchMatch')].map(e => {
     const from = v.posAtDOM(e, 0), to = v.posAtDOM(e, e.childNodes.length);
     return [from, to, e.classList.contains('cm-searchMatch-selected') ? 1 : 0]; });
  const ticks = [...document.querySelectorAll('button[aria-label^="Jump to match"]')].length;
  return {doc: v.state.doc.toString(), anchor: s.anchor, head: s.head, counter, hl, ticks,
          open: !!card, query: card ? card.querySelector('input').value : null}; })()"""


def call(o, fn, *args):
    return o.js(f"({fn})(...{json.dumps(list(args))})")


def main():
    o = boot()
    out = []
    for name, doc, a, h, query, rep, ops in CASES:
        # close any open overlay, reset doc
        o.js("document.querySelector('[data-search-overlay] button[aria-label=Close]')?.click()")
        o.js(f"__flo.setDoc({json.dumps(doc)}, {a}, {h})")
        call(o, KEYDOWN, ".cm-content", "f", "KeyF", 70, False, True)
        time.sleep(0.15)
        steps = [dict(op="open", **o.js(SNAP))]
        if query is not None:
            call(o, SETVAL, "[data-search-overlay] input[aria-label=Find]", query)
            time.sleep(0.05)
            steps.append(dict(op="query", **o.js(SNAP)))
        if any(op in ("replace", "all") for op in ops):
            o.js("document.querySelector('[data-search-overlay] button[aria-label=\"Toggle replace\"]').click()")
            time.sleep(0.05)
            call(o, SETVAL, "[data-search-overlay] input[aria-label=Replace]", rep)
            time.sleep(0.05)
        for op in ops:
            if op == "next":
                call(o, KEYDOWN, "[data-search-overlay] input[aria-label=Find]", "Enter", "Enter", 13, False, False)
            elif op == "prev":
                call(o, KEYDOWN, "[data-search-overlay] input[aria-label=Find]", "Enter", "Enter", 13, True, False)
            elif op == "modg":
                call(o, KEYDOWN, "[data-search-overlay] input[aria-label=Find]", "g", "KeyG", 71, False, True)
            elif op == "modshiftg":
                call(o, KEYDOWN, "[data-search-overlay] input[aria-label=Find]", "G", "KeyG", 71, True, True)
            elif op == "replace":
                call(o, KEYDOWN, "[data-search-overlay] input[aria-label=Replace]", "Enter", "Enter", 13, False, False)
            elif op == "all":
                o.js("[...document.querySelectorAll('[data-search-overlay] button')].find(b => b.textContent === 'All').click()")
            time.sleep(0.05)
            steps.append(dict(op=op, **o.js(SNAP)))
        # undo of the last replace step, when any
        if any(op in ("replace", "all") for op in ops):
            o.js("__flo.view().focus()")
            call(o, KEYDOWN, ".cm-content", "z", "KeyZ", 90, False, True)
            time.sleep(0.05)
            steps.append(dict(op="undo", **o.js(SNAP)))
        if any(op in ("replace", "all") for op in ops):
            o.js("document.querySelector('[data-search-overlay] button[aria-label=\"Toggle replace\"]').click()")
        out.append(dict(name=name, doc=doc, anchor=a, head=h, query=query, replace=rep, ops=ops, steps=steps))
        print(name, steps[-1]["counter"], file=sys.stderr)
    Path(__file__).parent.parent.joinpath("fixtures", "find-wk.json").write_text(json.dumps(out, indent=1, ensure_ascii=False))
    o.close()


if __name__ == "__main__":
    main()
