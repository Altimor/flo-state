import json, sys, statistics as st
import os
R=json.load(open(os.environ.get("RENDER", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures", "render.json"))))
name, tag, nat = sys.argv[1], sys.argv[2], json.load(open(sys.argv[3]))
r=[x for x in R if x["name"]==name and x["caretTag"]==tag][0]
d=r["doc"]; N=nat["chars"]
dx=[];dy=[];rows=[]
lines=[(l["from"],l["to"]) for l in r["lines"]]
for (f,t) in lines[:40]:
    for i in range(f,t):
        c=r["chars"][i]; n=N[i] if i<len(N) else None
        if not c or not c[1] or not n or c[4]<0.5: continue
        s=r["styles"][c[0]]
        if s["color"]=="rgba(0, 0, 0, 0)": continue
        dx.append(n[0]-c[2]); dy.append(n[1]-c[3])
        rows.append((i,d[f:t][:28],n[0]-c[2],n[1]-c[3],c[4],n[2]))
        break  # first visible char per line
for row in rows[:25]: print(f"{row[0]:6} {row[1]!r:32} dx={row[2]:7.2f} dy={row[3]:7.2f}  w_or={row[4]:6.2f} w_na={row[5]:6.2f}")
