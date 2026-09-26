"""block_probe.py cases.json: [name, 'doc', caret] 'doc' caret [selector] -> web.png native.png side.png + element rects"""
import json, sys, subprocess, time, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import boot
from paths import tmpdir, native_binary
from PIL import Image
S = os.environ.get("OUT") or str(tmpdir("block-probe")); os.makedirs(S, exist_ok=True)
NATIVE = str(native_binary())
def run(cases, height=900, sel=".cm-table-widget table, .cm-table-widget th, .cm-table-widget td"):
    DARK = os.environ.get("MODE") == "dark"
    st = {"appearance.theme": "dark", "theme.dark.accent": "#FF6A00", "theme.dark.background": "#111111", "theme.dark.foreground": "#FCFCFC",
          "theme.dark.heading-color": "#F0F0F0", "theme.dark.contrast": 16, "theme.dark.translucent": 0, "editor.subheading-color": "#3a3a3a"} if DARK else {"appearance.theme": "light"}
    o = boot(port=9350, height=height, settings=st)
    res = []
    for name, doc, caret in cases:
        o.js(f"__flo.setDoc({json.dumps(doc)}, {caret})"); time.sleep(0.6)
        rects = o.js(f"[...document.querySelectorAll({json.dumps(sel)})].map(e => {{ const b = e.getBoundingClientRect(); return [e.tagName, Math.round(b.left*100)/100, Math.round(b.top*100)/100, Math.round(b.width*100)/100, Math.round(b.height*100)/100] }})")
        lines = o.js("[...document.querySelectorAll('.cm-content > *')].map(e => { const b = e.getBoundingClientRect(); return [e.className, b.top, b.height] })")
        o.screenshot(f"{S}/{name}-web.png")
        open(f"{S}/{name}.md", "w").write(doc)
        subprocess.run([NATIVE, "--snapshot", f"{S}/{name}.md", "--caret", str(caret), "--height", str(height), "--out", f"{S}/{name}-native.png", "--geometry", f"{S}/{name}-g.json"] + (["--dark"] if DARK else []), check=True)
        a = Image.open(f"{S}/{name}-web.png"); b = Image.open(f"{S}/{name}-native.png")
        # crop to text column region
        wx = o.js("document.querySelector('.cm-content').getBoundingClientRect().left")
        g = json.load(open(f"{S}/{name}-g.json"))
        acc = 0; ai = 0
        for ln in doc.split("\n"):
            if ln.strip() and ln[0].isalpha(): ai = acc; break
            acc += len(ln.encode("utf-16-le")) // 2 + 1
        ai = int(os.environ.get("ALIGN", ai))
        nx = g["chars"][ai][0]
        rx = o.js(f"__flo.render().chars[{ai}][2]")
        W = 900
        a = a.crop((int(2*(rx-100)), 0, int(2*(rx-100+W)), a.height)); b = b.crop((int(2*(nx-100)), 0, int(2*(nx-100+W)), b.height))
        side = Image.new("RGB", (a.width * 2 + 20, a.height), "red")
        side.paste(a, (0, 0)); side.paste(b, (a.width + 20, 0))
        side = side.resize((side.width // 2, side.height // 2))
        side.save(f"{S}/{name}-side.png")
        res.append((name, rects, lines))
        print(name, json.dumps(rects)); print("  lines", json.dumps(lines[:40]))
    o.close()
    return res
if __name__ == "__main__":
    cases = json.load(open(sys.argv[1]))
    run([tuple(c) for c in cases], height=int(os.environ.get("H", "900")), sel=os.environ.get("SEL", ".cm-table-widget table, .cm-table-widget th, .cm-table-widget td"))
