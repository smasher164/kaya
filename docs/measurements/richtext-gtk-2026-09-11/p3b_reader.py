#!/usr/bin/env python3
import json, time
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib

OUT=[]
def say(s=""):
    OUT.append(s); print(s, flush=True)
    open("/out/p3b_atspi.txt","w",encoding="utf-8").write("\n".join(OUT)+"\n")

def walk(a, d=0, out=None, maxd=8):
    out = [] if out is None else out
    try:
        out.append((d, a.get_role_name(), a.get_name(), list(Atspi.Accessible.get_interfaces(a)), a))
    except Exception: return out
    if d < maxd:
        for i in range(a.get_child_count()):
            try: walk(a.get_child_at_index(i), d+1, out, maxd)
            except Exception: pass
    return out

def fmt(v):
    try:
        d,s,e = v[0],v[1],v[2]
        return "[%d,%d) {%s}" % (s,e,", ".join("%s=%s"%(k,d[k]) for k in sorted(d)))
    except Exception: return repr(v)

Atspi.init()
spans = json.load(open("/out/p3b_spans.json",encoding="utf-8"))
target=None
for _ in range(30):
    dsk = Atspi.get_desktop(0)
    tree=[]
    for i in range(dsk.get_child_count()):
        tree += walk(dsk.get_child_at_index(i))
    for d,r,n,ifs,acc in tree:
        if "Text" in ifs:
            try: txt = Atspi.Text.get_text(acc,0,-1)
            except Exception: continue
            if txt and "size_units" in txt:
                target = acc; break
    if target: break
    time.sleep(0.5)
say("=== probe 3b — AT-SPI follow-ups ===")
if target is None:
    say("target not found"); raise SystemExit

say("text = %r" % Atspi.Text.get_text(target,0,-1))
say("\n--- per-tag non-default attribute run ---")
for sp in spans["spans"]:
    off = (sp["char_start"]+sp["char_end"])//2
    try:
        r = Atspi.Text.get_attribute_run(target, off, False)
    except Exception as e:
        r = "ERR %r"%(e,)
    say("  %-12s chars[%3d,%3d) off=%3d -> %s" % (sp["tag"], sp["char_start"], sp["char_end"], off, fmt(r)))

say("\n--- BOUNDARY: reads straddling two adjacent runs ---")
for sp in spans["spans"]:
    if sp["tag"].startswith("BOUNDARY"):
        for off in [sp["char_start"], sp["char_start"]+1, sp["char_end"]-1, sp["char_end"]]:
            try: r = Atspi.Text.get_attribute_run(target, off, False)
            except Exception as e: r="ERR %r"%(e,)
            say("  %s offset %3d -> %s" % (sp["tag"], off, fmt(r)))

say("\n--- the full Atspi.Text method surface available to a reader ---")
say("  " + ", ".join(sorted(m for m in dir(Atspi.Text) if not m.startswith("_"))))

say("\n--- LIVE: does applying a tag emit an AT-SPI event? (listening 20s) ---")
seen=[]
def cb(ev):
    try:
        if ev.source == target or True:
            seen.append((ev.type, getattr(ev,'detail1',None), getattr(ev,'detail2',None),
                         str(getattr(ev,'any_data',''))[:40]))
            say("    EVENT %s d1=%s d2=%s data=%r" % (ev.type, ev.detail1, ev.detail2, str(ev.any_data)[:40]))
    except Exception as e:
        say("    EVENT err %r" % (e,))
listeners=[]
for t in ["object:text-attributes-changed","object:attributes-changed",
          "object:text-changed","object:property-change","object:state-changed"]:
    l = Atspi.EventListener.new(cb)
    l.register(t); listeners.append(l)
GLib.timeout_add_seconds(20, lambda: (Atspi.event_quit(), False)[-1])
Atspi.event_main()
say("  events seen: %d" % len(seen))
say("  text-attributes-changed seen: %s"
    % ("YES" if any("attributes-changed" in s[0] for s in seen) else "NO"))
