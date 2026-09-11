#!/usr/bin/env python3
"""Probe 3 reader half: read the probe app's text attributes over AT-SPI,
exactly as a screen reader would."""
import json, sys, time
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

OUT = []
def say(*a):
    s = " ".join(str(x) for x in a); OUT.append(s); print(s, flush=True)

def find_app(name, tries=40):
    for _ in range(tries):
        d = Atspi.get_desktop(0)
        for i in range(d.get_child_count()):
            c = d.get_child_at_index(i)
            try:
                n = c.get_name()
            except Exception:
                continue
            if n and name in n:
                return c
        time.sleep(0.5)
    return None

def walk(acc, depth=0, out=None, maxd=8):
    if out is None: out = []
    try:
        role = acc.get_role_name(); name = acc.get_name()
        ifs = Atspi.Accessible.get_interfaces(acc)
    except Exception as e:
        return out
    out.append((depth, role, name, list(ifs), acc))
    if depth < maxd:
        for i in range(acc.get_child_count()):
            try:
                walk(acc.get_child_at_index(i), depth + 1, out, maxd)
            except Exception:
                pass
    return out

def attrs_at(txt, off):
    """Call Text.get_attributes / get_attribute_run defensively across binding shapes."""
    res = {}
    try:
        r = Atspi.Text.get_attributes(txt, off)
        res["get_attributes"] = r
    except Exception as e:
        res["get_attributes"] = "ERR %r" % (e,)
    try:
        r = Atspi.Text.get_attribute_run(txt, off, True)
        res["get_attribute_run(incl_defaults=True)"] = r
    except Exception as e:
        res["get_attribute_run(incl_defaults=True)"] = "ERR %r" % (e,)
    try:
        r = Atspi.Text.get_attribute_run(txt, off, False)
        res["get_attribute_run(incl_defaults=False)"] = r
    except Exception as e:
        res["get_attribute_run(incl_defaults=False)"] = "ERR %r" % (e,)
    return res

def fmt(v):
    if isinstance(v, str): return v
    try:
        # (dict, start, end)
        d, s, e = v[0], v[1], v[2]
        items = ", ".join("%s=%s" % (k, d[k]) for k in sorted(d))
        return "[%d,%d) {%s}" % (s, e, items)
    except Exception:
        pass
    try:
        items = ", ".join("%s=%s" % (k, v[k]) for k in sorted(v))
        return "{%s}" % items
    except Exception:
        return repr(v)

def main():
    Atspi.init()
    say("=== AT-SPI reader ===")
    spans = json.load(open("/out/p3_spans.json", encoding="utf-8"))
    d = Atspi.get_desktop(0)
    say("desktop children: %s" % [d.get_child_at_index(i).get_name()
                                  for i in range(d.get_child_count())])
    tree = []
    for i in range(d.get_child_count()):
        tree += walk(d.get_child_at_index(i))
    say("\n--- accessible tree ---")
    for depth, role, name, ifs, _ in tree:
        say("  %s%-22s name=%-28r ifaces=%s" % ("  " * depth, role, name, ",".join(ifs)))

    # the text view: the node with a Text interface that holds our buffer text
    target = None
    for depth, role, name, ifs, acc in tree:
        if "Text" in ifs:
            try:
                t = Atspi.Text.get_text(acc, 0, -1)
            except Exception:
                continue
            if "namedonly" in (t or ""):
                target = acc; break
    if target is None:
        say("\nNO accessible with a Text interface holding the buffer text")
        return
    say("\n--- target: role=%s ifaces=%s ---" % (target.get_role_name(),
        ",".join(Atspi.Accessible.get_interfaces(target))))
    full = Atspi.Text.get_text(target, 0, -1)
    say("Text.get_text(0,-1) = %r" % full)
    say("Text.get_character_count() = %s" % Atspi.Text.get_character_count(target))

    say("\n--- Text.get_default_attributes() ---")
    try:
        say("  " + fmt(Atspi.Text.get_default_attributes(target)))
    except Exception as e:
        say("  ERR %r" % (e,))
    try:
        say("  get_default_attribute_set: " + fmt(Atspi.Text.get_default_attribute_set(target)))
    except Exception as e:
        say("  get_default_attribute_set ERR %r" % (e,))

    say("\n--- per-span attributes (offsets are AT-SPI CHARACTER offsets) ---")
    for sp in spans["spans"]:
        if not sp["tag"] or not sp["text"].strip():
            continue
        off = (sp["char_start"] + sp["char_end"]) // 2
        say("\n  TAG %-10s chars[%d,%d) text=%r  probe offset %d"
            % (sp["tag"], sp["char_start"], sp["char_end"], sp["text"], off))
        for k, v in attrs_at(target, off).items():
            say("     %-38s %s" % (k, fmt(v)))

    say("\n--- a PLAIN offset for contrast (offset 2, 'plain ') ---")
    for k, v in attrs_at(target, 2).items():
        say("     %-38s %s" % (k, fmt(v)))

    say("\n--- is there a Hypertext / link surface? ---")
    ifs = Atspi.Accessible.get_interfaces(target)
    say("  target interfaces: %s" % ",".join(ifs))
    say("  'Hypertext' present: %s" % ("Hypertext" in ifs))
    if "Hypertext" in ifs:
        try:
            n = Atspi.Hypertext.get_n_links(target)
            say("  n_links = %s" % n)
            for i in range(n):
                l = Atspi.Hypertext.get_link(target, i)
                say("    link %d: start=%s end=%s uri=%s" % (
                    i, Atspi.Hyperlink.get_start_index(l), Atspi.Hyperlink.get_end_index(l),
                    Atspi.Hyperlink.get_uri(l, 0)))
        except Exception as e:
            say("  hypertext ERR %r" % (e,))
    say("  any accessible in the tree with role 'link': %s"
        % [ (r, n) for _, r, n, _, _ in tree if "link" in r ])

    say("\n--- EditableText present (so a screen reader treats it as editable)? %s ---"
        % ("EditableText" in ifs))

main()
open("/out/p3_atspi.txt", "w", encoding="utf-8").write("\n".join(OUT) + "\n")
