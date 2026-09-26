"""Record the web editor context menu (fixtures/menu-wk.json): the items the
app builds for a right-click (with and without a link under the pointer),
and the document after running each formatting/insert action.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cdp import boot

HOOK = """(() => { if (window.__menu) return; window.__menu = []; const orig = window.__TAURI_INTERNALS__.invoke;
 window.__TAURI_INTERNALS__.invoke = function(cmd, args, opts) {
   if (cmd === 'plugin:menu|new') window.__menu.push({kind: args.kind, options: JSON.parse(JSON.stringify(args.options || {})),
      handler: args.handler ? args.handler.id : null});
   return orig.call(this, cmd, args, opts); }; })()"""

RIGHT_CLICK = """(pos) => { window.__menu.length = 0; const v=__flo.view(); const c=v.coordsAtPos(pos);
  document.querySelector('.cm-content').dispatchEvent(new MouseEvent('contextmenu', {clientX: c.left + 1, clientY: (c.top + c.bottom) / 2, bubbles: true, cancelable: true})); return 1 }"""

FIRE = """(id) => { const it = window.__menu.find(m => m.options && m.options.id === id); if (!it) return 'missing';
  const ch = it.handler; try { window.__TAURI_INTERNALS__.runCallback(ch, {index: 0, message: id}); } catch (e) { return 'threw: ' + e.message } return 'ok' }"""

SNAP = """(() => { const v=__flo.view(); const s=v.state.selection.main; return {doc: v.state.doc.toString(), anchor: s.anchor, head: s.head}; })()"""

ACTIONS = [
    # (doc, anchor, head, right-click pos, item id)
    ("hello **bold** and *it* ~~s~~ `c`", 0, 33, 3, "fmt.clear"),
    ("hello world", 6, 11, 7, "fmt.bold"),
    ("hello world", 3, 3, 3, "fmt.italic"),
    ("hello world", 0, 5, 3, "fmt.strikethrough"),
    ("hello world", 0, 5, 3, "fmt.code"),
    ("hello world", 0, 5, 3, "fmt.link"),
    ("hello world", 2, 2, 3, "para.h2"),
    ("## hello", 5, 5, 3, "para.paragraph"),
    ("a\nb\nc", 0, 5, 1, "para.bullet"),
    ("a\nb\nc", 0, 5, 1, "para.numbered"),
    ("a\nb", 0, 3, 1, "para.task"),
    ("a\nb", 0, 3, 1, "para.blockquote"),
    ("a\nb", 0, 3, 1, "para.codeblock"),
    ("```\na\n```", 0, 9, 1, "para.codeblock"),
    ("text", 4, 4, 1, "ins.table"),
    ("text", 4, 4, 1, "ins.hr"),
    ("", 0, 0, 0, "ins.hr"),
    ("hello world", 0, 5, 3, "cut"),
    ("hello world", 2, 2, 3, "select-all"),
]


def main():
    o = boot()
    o.js(HOOK)
    out = {"menus": {}, "actions": []}
    for label, doc, pos in [("plain", "plain text here", 3), ("link", "see [site](https://x.com) end", 6),
                            ("url", "go https://example.com/a now", 8), ("autolink", "a <https://e.com> b", 5),
                            ("wiki", "a [[Note]] b", 5), ("link-edge", "[a](u)[b](v)", 6)]:
        o.js(f"__flo.setDoc({json.dumps(doc)}, 0, 0)")
        o.js(f"({RIGHT_CLICK})({pos})")
        time.sleep(0.3)
        out["menus"][label] = {"doc": doc, "pos": pos, "items": o.js("window.__menu.map(m => [m.kind, m.options.id || m.options.item || null, m.options.text || null, m.options.accelerator || null])")}
    for doc, a, h, pos, item in ACTIONS:
        o.js(f"__flo.setDoc({json.dumps(doc)}, {a}, {h})")
        before = o.js(SNAP)
        o.js(f"({RIGHT_CLICK})({pos})")
        time.sleep(0.2)
        r = o.js(f"({FIRE})({json.dumps(item)})")
        time.sleep(0.3)
        after = o.js(SNAP)
        out["actions"].append({"doc": doc, "anchor": a, "head": h, "pos": pos, "item": item, "fired": r, "before": before, "after": after,
                               "clipboard": o.control(op="get_clipboard") if False else None})
        print(item, r, json.dumps(after["doc"]), file=sys.stderr)
    Path(__file__).parent.parent.joinpath("fixtures", "menu-wk.json").write_text(json.dumps(out, indent=1, ensure_ascii=False))
    o.close()


if __name__ == "__main__":
    main()
