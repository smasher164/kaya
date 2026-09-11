#!/usr/bin/env python3
import json, time
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib
OUT=[]
def say(s=""):
    OUT.append(s); print(s, flush=True)
    open("/out/p3c_atspi.txt","w",encoding="utf-8").write("\n".join(OUT)+"\n")
def walk(a,d=0,out=None,maxd=8):
    out=[] if out is None else out
    try: out.append((d,a.get_role_name(),a.get_name(),list(Atspi.Accessible.get_interfaces(a)),a))
    except Exception: return out
    if d<maxd:
        for i in range(a.get_child_count()):
            try: walk(a.get_child_at_index(i),d+1,out,maxd)
            except Exception: pass
    return out
def fmt(v):
    try:
        d,s,e=v[0],v[1],v[2]
        return "[%d,%d) {%s}"%(s,e,", ".join("%s=%s"%(k,d[k]) for k in sorted(d)))
    except Exception: return repr(v)
Atspi.init()
spans=json.load(open("/out/p3c_spans.json",encoding="utf-8"))
target=None
for _ in range(30):
    dsk=Atspi.get_desktop(0); tree=[]
    for i in range(dsk.get_child_count()): tree+=walk(dsk.get_child_at_index(i))
    for d,r,n,ifs,acc in tree:
        if "Text" in ifs:
            try: t=Atspi.Text.get_text(acc,0,-1)
            except Exception: continue
            if t and "CONTROLZONE" in t: target=acc; break
    if target: break
    time.sleep(0.5)
say("=== probe 3c — colour serialization + event listener with a positive control ===")
if target is None: say("target not found"); raise SystemExit
say("text = %r" % Atspi.Text.get_text(target,0,-1))
say("\n--- colour matrix: what AT-SPI publishes for a tag's colour ---")
say("  (expected 16-bit form: #rrggbb -> r*257, g*257, b*257)")
for sp in spans["spans"]:
    off=(sp["char_start"]+sp["char_end"])//2
    try: r=Atspi.Text.get_attribute_run(target,off,False)
    except Exception as e: r="ERR %r"%(e,)
    hexc = sp["tag"].split()[1].lstrip("#")
    exp = ",".join(str(int(hexc[i:i+2],16)*257) for i in (0,2,4))
    say("  %-12s expected %-20s got %s" % (sp["tag"], exp, fmt(r)))
say("\n--- LIVE events: control (insert/delete) vs test (apply-tag) ---")
seen=[]
def cb(ev):
    try:
        seen.append(ev.type)
        say("    EVENT %-40s d1=%s d2=%s data=%r" % (ev.type, ev.detail1, ev.detail2, str(ev.any_data)[:30]))
    except Exception as e: say("    EVENT err %r"%(e,))
ls=[]
for t in ["object:text-attributes-changed","object:attributes-changed",
          "object:text-changed","object:property-change"]:
    l=Atspi.EventListener.new(cb); l.register(t); ls.append(l)
say("  listening 18s (control insert at t~8s, tag at t~12s, delete at t~16s from app start)")
GLib.timeout_add_seconds(18, lambda:(Atspi.event_quit(),False)[-1])
Atspi.event_main()
say("\n  total events: %d" % len(seen))
say("  object:text-changed*          seen (POSITIVE CONTROL): %s"
    % ("YES" if any("text-changed" in s for s in seen) else "NO — the listener itself is not working, so nothing below is conclusive"))
say("  object:text-attributes-changed seen (THE TEST):        %s"
    % ("YES" if any("text-attributes-changed" in s for s in seen) else "NO"))
