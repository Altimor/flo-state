"""Record the web app's wiki-link autocomplete (fixtures/wiki-wk.json).

Each case types characters with CM `input.type` transactions, either slowly
(each char waits out the 100 ms activate-on-typing debounce, so the source is
queried after the first character and later chars only re-filter) or fast
(one query at the end), then optionally presses keys. After each step we
record the popup's options (label html incl. matched-text spans, detail,
selected) and the document. The mock backend's fuzzy_search results for every
query issued are stored too, so the native test can replay the same source.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cdp import boot

CASES = [
    # name, initial doc, caret, [(chars, slow?)...], keys after
    ("single-char", "x\n", 2, [("[[m", True)], []),
    ("slow-no", "x\n", 2, [("[[n", True), ("o", True), ("t", True)], []),
    ("fast-not", "x\n", 2, [("[[not", False)], []),
    ("fast-master", "", 0, [("[[master", False)], ["ArrowDown", "Enter"]),
    ("accept-first", "", 0, [("[[top", False)], ["Enter"]),
    ("consume-close", "a [[]] b", 4, [("to", False)], ["Enter"]),
    ("ambiguous", "", 0, [("[[master note", False)], ["Enter"]),
    ("ambiguous-2", "", 0, [("[[master note", False)], ["ArrowDown", "Enter"]),
    ("dir-detail", "", 0, [("[[growth", False)], []),
    ("wrap-up", "", 0, [("[[e", False)], ["ArrowUp"]),
    ("escape", "", 0, [("[[top", False)], ["Escape"]),
    ("space-only", "", 0, [("[[ ", False)], []),
    ("hash-stops", "", 0, [("[[top#", False)], []),
    ("in-code", "`x ", 3, [("[[top", False)], []),
    ("fenced", "```\n", 4, [("[[top", False)], []),
    ("upper", "", 0, [("[[TOP", False)], []),
    ("fuzzy-gap", "", 0, [("[[a", True), ("r", True), ("c", True)], []),
    ("slow-e-i", "", 0, [("[[e", True), ("i", True)], []),
    ("backspace", "", 0, [("[[fo", False)], ["Backspace"]),
    ("backspace-all", "", 0, [("[[f", False)], ["Backspace"]),
    ("emoji", "", 0, [("[[📓", False)], ["Enter"]),
    ("pageup", "", 0, [("[[a", False)], ["PageDown", "PageDown", "PageUp"]),
]

TYPE = """(ch) => { const v=__flo.view(); const p=v.state.selection.main.head;
  v.dispatch({changes:{from:p,insert:ch}, selection:{anchor:p+ch.length}, userEvent:'input.type'}); return 1 }"""

SNAP = """(() => { const v=__flo.view(); const t=document.querySelector('.cm-tooltip-autocomplete');
  const opts = t ? [...t.querySelectorAll('li')].map(li => ({label: li.querySelector('.cm-completionLabel').innerHTML,
     detail: li.querySelector('.cm-completionDetail')?.textContent ?? null, selected: li.getAttribute('aria-selected') === 'true'})) : null;
  return {doc: v.state.doc.toString(), head: v.state.selection.main.head, options: opts}; })()"""

KEYS = {"Enter": 13, "Escape": 27, "ArrowDown": 40, "ArrowUp": 38, "PageDown": 34, "PageUp": 33, "Backspace": 8}


def main():
    o = boot()
    # record the queries the source issues
    o.js("""(() => { if (window.__fq) return; window.__fq = []; const orig = window.__TAURI_INTERNALS__.invoke;
      window.__TAURI_INTERNALS__.invoke = function(cmd, args, opts) { if (cmd === 'fuzzy_search') window.__fq.push(args.query); return orig.call(this, cmd, args, opts); }; })()""")
    out = []
    for name, doc, caret, typing, keys in CASES:
        o.js(f"__flo.setDoc({json.dumps(doc)}, {caret}, {caret})")
        o.js("window.__fq.length = 0")
        steps = []
        for chars, slow in typing:
            if slow:
                for ch in chars:
                    o.js(f"({TYPE})({json.dumps(ch)})")
                    time.sleep(0.35)
            else:
                o.js(f"({TYPE})({json.dumps(chars)})")
                time.sleep(0.35)
            steps.append(dict(op="type:" + chars, **o.js(SNAP)))
        for k in keys:
            time.sleep(0.1)
            if k == "Backspace":
                o.js("__flo.view().focus()")
                o.js("""(() => { const v=__flo.view(); const p=v.state.selection.main.head; v.dispatch({changes:{from:p-1,to:p}, userEvent:'delete.backward'}); })()""")
            else:
                o.js(f"""document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {{key: {json.dumps(k)}, keyCode: {KEYS[k]}, bubbles: true, cancelable: true}}))""")
            time.sleep(0.35)
            steps.append(dict(op="key:" + k, **o.js(SNAP)))
        queries = o.js("window.__fq.slice()")
        results = {q: o.js(f"window.__TAURI_INTERNALS__.invoke('fuzzy_search', {{query: {json.dumps(q)}, limit: 20}})") for q in queries}
        o.js("window.__fq.length = 0")
        o.js("""document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', keyCode: 27, bubbles: true, cancelable: true}))""")
        out.append(dict(name=name, doc=doc, caret=caret, typing=typing, keys=keys, steps=steps, queries=queries, results=results))
        print(name, queries, [s["options"] and len(s["options"]) for s in steps], file=sys.stderr)
    Path(__file__).parent.parent.joinpath("fixtures", "wiki-wk.json").write_text(json.dumps(out, indent=1, ensure_ascii=False))
    o.close()


if __name__ == "__main__":
    main()
