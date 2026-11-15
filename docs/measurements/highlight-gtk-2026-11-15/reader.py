#!/usr/bin/env python3
"""The AT-SPI attribute run of each probe word (docs/highlight-plan.md §3)."""
import json, time
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

out = []
def say(s):
    out.append(s); print(s, flush=True)
    open("/out/atspi.txt", "w").write("\n".join(out) + "\n")
def walk(a, acc):
    try:
        acc.append(a)
        for i in range(a.get_child_count()):
            walk(a.get_child_at_index(i), acc)
    except Exception:
        pass
    return acc
Atspi.init()
spans = json.load(open("/out/spans.json"))
target = None
for _ in range(40):
    d = Atspi.get_desktop(0)
    for a in walk(d, []):
        try:
            if "Text" in Atspi.Accessible.get_interfaces(a) and "MARKONLY" in Atspi.Text.get_text(a, 0, -1):
                target = a
        except Exception:
            pass
    if target:
        break
    time.sleep(0.5)
if target is None:
    say("target not found"); raise SystemExit(1)
for sp in spans["spans"]:
    mid = (sp["start"] + sp["end"]) // 2
    attrs, s, e = Atspi.Text.get_attribute_run(target, mid, False)
    keep = {k: attrs[k] for k in sorted(attrs) if k.startswith("bg")}
    say("%-13s run [%d,%d) %s" % (sp["word"], s, e, keep))
