import json, sys, bisect
import os
R=json.load(open(os.environ.get("RENDER", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures", "render.json"))))
name, tag, natp = sys.argv[1], sys.argv[2], sys.argv[3]
nat=json.load(open(natp))
r=[x for x in R if x["name"]==name and x["caretTag"]==tag][0]
d=r["doc"]
starts=[0]+[i+1 for i,c in enumerate(d) if c=="\n"]
bad=0
for l in r["lines"]:
    if l["from"]==l["to"]: continue  # empty lines: oracle reports next-line offsets
    n=bisect.bisect_right(starts,l["from"])-1
    if n>=len(nat["lineTops"]): break
    diff=nat["lineTops"][n]-l["top"]
    if n>0 and abs(diff)>0.6:
        bad+=1
        if bad<=12: print(f"line {n+1}: oracle {l['top']} native {nat['lineTops'][n]:.1f} diff {diff:.1f}  {d[l['from']:l['to']][:50]!r}")
print("lines compared", len(r["lines"]), "bad", bad)
