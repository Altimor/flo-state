"""Geometry parity: native char x + visual row vs the oracle, all render fixtures."""
import json, subprocess, sys, collections
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paths import FIXTURES, native_binary, tmpdir
R = json.load(open(os.environ.get("RENDER", FIXTURES / "render-wk.json")))
TOL = float(os.environ.get("TOL", "1.5"))
S = str(tmpdir("geom-parity"))
only = sys.argv[1] if len(sys.argv) > 1 else ""
cases = [r for r in R if only in r["name"]]
json.dump([{"doc": r["doc"], "caret": r["caret"]} for r in cases], open(S + "/geom_in.json", "w"))
subprocess.run([str(native_binary()), "--batch-geometry", S + "/geom_in.json", S + "/geom_out.json"], check=True)
N = json.load(open(S + "/geom_out.json"))
tot = badx = bady = 0
worst = collections.Counter(); ex = {}
for r, n in zip(cases, N):
    d = r["doc"]; C = r["chars"]; NC = n["chars"]
    # UTF-16 low surrogates: the web reports a collapsed rect at the pair's start (not a real position)
    u16 = d.encode("utf-16-le"); low = {i for i in range(len(u16) // 2) if 0xDC00 <= int.from_bytes(u16[2*i:2*i+2], "little") <= 0xDFFF}
    # the oracle's column may sit elsewhere (sidebar): align on the median x offset
    diffs = sorted(C[i][2] - NC[i][0] for i in range(min(len(C), len(NC))) if C[i] and NC[i] and C[i][1] and i not in low)
    DX = diffs[len(diffs) // 2] if diffs else 0
    DX = round(DX * 2) / 2 if abs(DX) > 100 else 0
    for l in r["lines"]:
        vis = [i for i in range(l["from"], l["to"]) if i not in low and C[i] and C[i][1] and (C[i][4] or 0) > 0.5
               and r["styles"][C[i][0]]["color"] != "rgba(0, 0, 0, 0)" and i < len(NC) and NC[i]
               and "cm-heading-hash" not in " ".join(r["styles"][C[i][0]]["classes"])]
        if not vis: continue
        # calibrate vertical offset on first char of the line
        oy0, ny0 = C[vis[0]][3], NC[vis[0]][1]
        rows_o = {}; rows_n = {}
        for i in vis:
            tot += 1
            ro = round(C[i][3] - oy0); rn = round(NC[i][1] - ny0)
            okx = abs(NC[i][0] + DX - C[i][2]) < TOL
            # compare which visual row (relative) each char lands on
            rows_o.setdefault(ro, len(rows_o)); rows_n.setdefault(rn, len(rows_n))
            oky = rows_o[ro] == rows_n[rn]
            if not okx: badx += 1
            if not oky: bady += 1
            if not (okx and oky):
                k = f"{r['name']}|{'x' if not okx else 'row'}|{round(NC[i][0]+DX-C[i][2])}"
                worst[k] += 1
                ex.setdefault(k, f"@{i} {d[max(0,i-15):i+5]!r} ox={C[i][2]} nx={NC[i][0]:.1f} row o{rows_o[ro]} n{rows_n[rn]}")
print(f"GEOMETRY: {tot - max(badx, bady)}/{tot} chars ok  (x off: {badx}, row off: {bady})")
for k, v in worst.most_common(int(os.environ.get("TOP", "15"))): print(f"  {v:5} {k}  e.g. {ex[k]}")
