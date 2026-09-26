"""Pixel-level parity: per rendered line, compare glyph ink extents between the
web app (headless Chrome, 2x) and the native snapshot (2x)."""
import json, sys, subprocess, time, os
sys.path.insert(0, os.path.dirname(__file__))
import numpy as np
from PIL import Image
from cdp import boot
from paths import ensure_sandbox, native_binary, tmpdir

NATIVE = str(native_binary())
TMP = str(tmpdir("ink-parity"))

def ink_rows(im, y0, y1, x0=300, x1=1100):
    reg = im[int(y0 * 2):int(y1 * 2), x0 * 2:x1 * 2]
    dark = reg < 200
    rows = np.where(dark.any(axis=1))[0]
    cols = np.where(dark.any(axis=0))[0]
    if rows.size == 0: return None
    return (rows.min() / 2 + y0, rows.max() / 2 + y0, cols.min() / 2 + x0, cols.max() / 2 + x0)

def run(docs, caret_end=False, height=1600):
    o = boot(port=9348, height=height)
    bad = total = 0
    for name, doc in docs:
        caret = len(doc.encode("utf-16-le")) // 2 if caret_end else 0
        o.js(f"__flo.setDoc({json.dumps(doc)}, {caret})"); time.sleep(0.4)
        tops = o.js("[...document.querySelectorAll('.cm-content > *')].map(e => { const b = e.getBoundingClientRect(); return [b.top, b.bottom] })")
        o.screenshot(f"{TMP}/o.png")
        open(f"{TMP}/doc.md", "w").write(doc)
        subprocess.run([NATIVE, "--snapshot", f"{TMP}/doc.md", "--caret", str(caret), "--height", str(height), "--out", f"{TMP}/n.png"], check=True)
        oi = np.asarray(Image.open(f"{TMP}/o.png").convert("L")).astype(int)
        ni = np.asarray(Image.open(f"{TMP}/n.png").convert("L")).astype(int)
        for (t, b) in tops:
            if b > height - 5: break
            total += 1
            a, n = ink_rows(oi, t, b), ink_rows(ni, t, b)
            if a is None and n is None: continue
            if a is None or n is None or max(abs(x - y) for x, y in zip(a, n)) > 0.5:
                bad += 1
                print(f"  {name} line {t:.1f}-{b:.1f}: web {a} native {n}")
    o.close()
    print(f"INK: {total - bad}/{total} lines within 0.5px")

if __name__ == "__main__":
    DOC = "# Heading one\n\nBody text with **bold** and *italic* and `code` here.\n\n## Heading two\n\n### Heading three\n\n- bullet item\n- [ ] task item\n- [x] done item\n\n1. first\n2. second\n\n> quoted text\n\n```\ncode block\n```\n\nA [link](http://x.com) and ~~strike~~.\n\n---\n\nlast line"
    run([("sample", DOC)] + ([(p.name, p.read_text()) for p in sorted(ensure_sandbox().rglob("*.md")) if p.name not in ("__oracle.md", "__img.md")][:int(sys.argv[1])] if len(sys.argv) > 1 else []))
