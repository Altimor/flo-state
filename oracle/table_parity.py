"""Numeric table layout parity: web cell rects vs native TableLayout dump."""
import json, sys, subprocess, time, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import boot
from paths import tmpdir, native_binary
S = os.environ.get("OUT") or str(tmpdir("table-parity")); os.makedirs(S, exist_ok=True)
NATIVE = str(native_binary())
long = "word " * 40
CASES = [
    "| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 | 4 |\n",
    "a | b\n--|--\n1 | 2\n",
    "| Name | Qty | Notes |\n|:--|:-:|--:|\n| **Apple** | 3 | `fresh` and [link](x) |\n| Pear | 12 | ~~old~~ *soft* |\n",
    "| h1 | h2 |\n|---|---|\n",
    "| only |\n|---|\n| x |\n",
    "| abcdefghij | abcdefghijk | abcdefghijklmnop |\n|---|---|---|\n| x | y | z |\n",
    f"| Col | Long |\n|---|---|\n| a | {long} |\n| b | short |\n",
    f"| {long} | {long} |\n|---|---|\n| {long} | x |\n",
    "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |\n",
    "| esc \\| pipe | [[Wiki Page]] | [[P#Head]] |\n|---|---|---|\n| :smile: emoji | a -- b --- c | &amp; &copy; &#65; |\n",
    "| Supercalifragilisticexpialidocious_and_more_letters_here | b |\n|---|---|\n| 1 | 2 |\n",
    "| `code` | **bold *nest*** | <b>html</b> |\n|---|---|---|\n| `a` `b` | ***x*** | https://example.com/x |\n",
    "| 日本語 | café | 📓 |\n|---|---|---|\n| 1 | 2 | 3 |\n",
    "|   spaced    out   | x |\n|---|---|\n|a|b|\n",
    "| h |\n|:-:|\n| centred cell text |\n",
]
def main():
    o = boot(port=9352, settings={"appearance.theme": "light"})
    bad = 0
    for k, t in enumerate(CASES):
        doc = "Intro\n\n" + t + "\nafter\n"
        o.js(f"__flo.setDoc({json.dumps(doc)}, 0)"); time.sleep(0.3)
        web = o.js("""(() => { const w = document.querySelector('.cm-table-widget'); if (!w) return null; const tb = w.querySelector('table').getBoundingClientRect();
          return {widget: w.getBoundingClientRect().height, top: tb.top - w.getBoundingClientRect().top, size: [tb.width, tb.height],
          cells: [...w.querySelectorAll('th,td')].map(e => { const b = e.getBoundingClientRect(); return [b.left - tb.left, b.top - tb.top, b.width, b.height] })} })()""")
        open(f"{S}/tt.md", "w").write(doc)
        r = subprocess.run([NATIVE, "--snapshot", f"{S}/tt.md", "--caret", "0", "--out", f"{S}/tt.png"], capture_output=True, text=True, env={**os.environ, "FLO_DUMP_TABLES": "1"})
        nat = [json.loads(l) for l in r.stderr.splitlines() if l.startswith("{")]
        nat = nat[0] if nat else None
        if web is None or nat is None:
            print(k, "missing", web is None, nat is None); bad += 1; continue
        diffs = []
        for key in ("widget", "top"):
            if abs(web[key] - nat[key]) > 0.5: diffs.append(f"{key} web {web[key]} nat {nat[key]}")
        for i in range(2):
            if abs(web["size"][i] - nat["size"][i]) > 0.5: diffs.append(f"size{i} web {web['size'][i]:.2f} nat {nat['size'][i]:.2f}")
        if len(web["cells"]) != len(nat["cells"]): diffs.append(f"ncells {len(web['cells'])} vs {len(nat['cells'])}")
        for j, (a, b) in enumerate(zip(web["cells"], nat["cells"])):
            if max(abs(x - y) for x, y in zip(a, b)) > 0.5: diffs.append(f"cell{j} web {[round(x,2) for x in a]} nat {[round(x,2) for x in b]}")
        print(k, "OK" if not diffs else "DIFF", "; ".join(diffs[:6]))
        bad += bool(diffs)
    print(f"TABLES: {len(CASES) - bad}/{len(CASES)}")
    o.close()
main()
