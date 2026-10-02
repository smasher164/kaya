import re, sys
cases=open('cases.txt',encoding='utf-8').read().split("\n")
def analyze(tag):
    d=open(f'{tag}-vtrace.txt','rb').read().decode('utf-8','replace')
    recs=[]
    for m in re.finditer(r't=(\d+) step=(\d+) verb=(\S+) try=\d+ what="(.*)"', d):
        recs.append((int(m.group(2)), m.group(3), m.group(4)))
    out=open(f'{tag}-out.txt','rb').read().decode('utf-8','replace')
    rows=[]
    for i,c in enumerate(cases):
        base=5*(2*i+1)
        notes=[w for s,v,w in recs if v=="number.settle" and base+2<=s<=base+4]
        if not notes: res="REFUSED (no commit; text reverted)"
        else:
            m=re.search(r'read=(\S+)', notes[-1]); res="read "+m.group(1)
            bt=re.search(r'box_text=(.*)$', notes[-1]); res+=f"  [{bt.group(1) if bt else ''}]"
            if len(notes)>1: res+=f" ({len(notes)} notes)"
        rows.append((c,res))
    warn=[l for l in out.splitlines() if "never showed" in l]
    return rows, warn, out.splitlines()[0]
for tag in sys.argv[1:]:
    rows,warn,first=analyze(tag)
    print("==",tag, first)
    for c,r in rows: print(f"  {c!r:14} -> {r}")
    for w in warn: print("  WARN", w[:200])
