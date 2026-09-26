"""Record the web editor's paste handling (fixtures/paste-wk.json): a synthetic
ClipboardEvent carrying text/plain, text/html and/or an image File goes
through the app's paste handler chain (frontmatter, image, rich HTML) and
CodeMirror's own plain-text paste.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cdp import boot

PNG_1PX = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196,
           137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 15, 4, 0, 9, 251, 3, 253, 227, 85, 242, 156, 0, 0, 0, 0, 73, 69,
           78, 68, 174, 66, 96, 130]

CASES = [
    # name, doc, anchor, head, plain, html, image(name, type) | None
    ("plain", "ab", 1, 1, "XY", None, None),
    ("plain-replace", "hello world", 0, 5, "bye", None, None),
    ("plain-crlf", "", 0, 0, "a\r\nb\rc", None, None),
    ("plain-multiline", "x", 1, 1, "l1\nl2\n", None, None),
    ("html-bold", "", 0, 0, "bold text", "<b>bold</b> text", None),
    ("html-list", "p ", 2, 2, "one\ntwo", "<ul><li>one</li><li>two</li></ul>", None),
    ("html-plain-only", "", 0, 0, "just text", "<span>just text</span>", None),
    ("html-same", "", 0, 0, "*a*", "<em>a</em>", None),
    ("html-link", "", 0, 0, "site", '<a href="https://x.com/a b">site</a>', None),
    ("html-table", "", 0, 0, "a b", "<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>", None),
    ("html-code", "", 0, 0, "x = 1", '<pre><code class="language-py">x = 1</code></pre>', None),
    ("image", "before after", 7, 7, None, None, ("image.png", "image/png")),
    ("image-over-html", "", 0, 0, "t", "<b>t</b>", ("shot.png", "image/png")),
    ("image-jpeg", "", 0, 0, None, None, ("photo.jpeg", "image/jpeg")),
    ("frontmatter", "body", 4, 4, "---\ntitle: X\n---\nhello", None, None),
    ("frontmatter-again", "body", 4, 4, "---\ntitle: Y\n---\nagain", None, None),
    ("frontmatter-only", "", 0, 0, "---\na: 1\n---\n", None, None),
]

PASTE = """async (plain, html, img, bytes) => {
  const dt = new DataTransfer();
  if (plain !== null) dt.setData('text/plain', plain);
  if (html !== null) dt.setData('text/html', html);
  if (img) dt.items.add(new File([new Uint8Array(bytes)], img[0], {type: img[1]}));
  const ev = new ClipboardEvent('paste', {clipboardData: dt, bubbles: true, cancelable: true});
  document.querySelector('.cm-content').dispatchEvent(ev);
  await new Promise(r => setTimeout(r, 400));
  const v = __flo.view(); const s = v.state.selection.main;
  return {doc: v.state.doc.toString(), anchor: s.anchor, head: s.head, prevented: ev.defaultPrevented};
}"""


def main():
    o = boot()
    out = []
    for name, doc, a, h, plain, html, img in CASES:
        o.js(f"__flo.setDoc({json.dumps(doc)}, {a}, {h})")
        o.js("__flo.view().focus()")
        r = o.js(f"({PASTE})({json.dumps(plain)}, {json.dumps(html)}, {json.dumps(img)}, {json.dumps(PNG_1PX)})")
        time.sleep(0.2)
        fm = o.js("(() => { const f = document.querySelector('[data-frontmatter]'); return f ? f.innerText : null })()")
        out.append(dict(name=name, doc=doc, anchor=a, head=h, plain=plain, html=html, image=img, result=r, frontmatterPanel=fm))
        print(name, json.dumps(r), file=sys.stderr)
    Path(__file__).parent.parent.joinpath("fixtures", "paste-wk.json").write_text(json.dumps(out, indent=1, ensure_ascii=False))
    o.close()


if __name__ == "__main__":
    main()
