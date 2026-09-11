#!/usr/bin/env python3
"""Probe 1 + 2: GtkTextBuffer undo scope (tags vs text) and undo suppression.

docs/rich-text-plan.md §3.1 (R6) and §3.5.
Run inside the kaya-linux container under Xvfb.
"""
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Pango, GLib

OUT = []
def say(*a):
    s = " ".join(str(x) for x in a)
    OUT.append(s)
    print(s, flush=True)

def mk():
    """A fresh view/buffer mirroring kaya's textarea: GtkTextView in a GtkScrolledWindow, editable."""
    buf = Gtk.TextBuffer()
    view = Gtk.TextView(buffer=buf)
    view.set_editable(True)
    sw = Gtk.ScrolledWindow()
    sw.set_child(view)
    win = Gtk.Window()
    win.set_default_size(600, 300)
    win.set_child(sw)
    return win, sw, view, buf

def text(buf):
    return buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)

def tags_at(buf, off):
    it = buf.get_iter_at_offset(off)
    return sorted(t.get_property("name") or "<anon>" for t in it.get_tags())

def bold_span(buf, tag):
    """Character offsets [start,end) where tag applies, as a list of runs."""
    runs = []
    it = buf.get_start_iter()
    n = buf.get_char_count()
    cur = None
    for off in range(n):
        i = buf.get_iter_at_offset(off)
        if i.has_tag(tag):
            if cur is None:
                cur = off
        else:
            if cur is not None:
                runs.append((cur, off)); cur = None
    if cur is not None:
        runs.append((cur, n))
    return runs

def undo_depth(buf, limit=20):
    """How many undos until can-undo goes false (non-destructive: we redo back)."""
    n = 0
    while buf.get_can_undo() and n < limit:
        buf.undo(); n += 1
    for _ in range(n):
        buf.redo()
    return n

def main():
    say("=== GTK", Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version(), "===")

    # ---------------- 1. enable-undo TRUE (the default) ----------------
    say("\n--- P1.0 default of enable-undo ---")
    b0 = Gtk.TextBuffer()
    say("enable-undo default =", b0.get_enable_undo())

    say("\n--- P1.1 CONTROL: undo of a plain insert ---")
    win, sw, view, buf = mk()
    say("can-undo at start =", buf.get_can_undo())
    buf.begin_user_action()
    buf.insert(buf.get_end_iter(), "hello world")
    buf.end_user_action()
    say("after insert: text=%r can-undo=%s can-redo=%s depth=%d"
        % (text(buf), buf.get_can_undo(), buf.get_can_redo(), undo_depth(buf)))
    buf.undo()
    say("after undo():  text=%r can-undo=%s can-redo=%s"
        % (text(buf), buf.get_can_undo(), buf.get_can_redo()))
    buf.redo()
    say("after redo():  text=%r" % text(buf))

    say("\n--- P1.2 THE QUESTION: undo of an attribute-only edit (apply-tag) ---")
    win, sw, view, buf = mk()
    bold = buf.create_tag("bold", weight=Pango.Weight.BOLD)
    buf.begin_user_action()
    buf.insert(buf.get_end_iter(), "hello world")
    buf.end_user_action()
    base_depth = undo_depth(buf)
    say("after insert:        text=%r can-undo=%s depth=%d tags@0=%s"
        % (text(buf), buf.get_can_undo(), base_depth, tags_at(buf, 0)))
    buf.begin_user_action()
    buf.apply_tag(bold, buf.get_iter_at_offset(0), buf.get_iter_at_offset(5))
    buf.end_user_action()
    d2 = undo_depth(buf)
    say("after apply_tag:     bold runs=%s can-undo=%s depth=%d (was %d) tags@0=%s"
        % (bold_span(buf, bold), buf.get_can_undo(), d2, base_depth, tags_at(buf, 0)))
    say("  >>> did the tag edit push an undo entry? %s" % ("YES" if d2 > base_depth else "NO"))
    buf.undo()
    say("after undo():        text=%r bold runs=%s tags@0=%s can-undo=%s can-redo=%s"
        % (text(buf), bold_span(buf, bold), tags_at(buf, 0), buf.get_can_undo(), buf.get_can_redo()))
    say("  >>> is the tag gone? %s" % ("YES" if not bold_span(buf, bold) else "NO — the tag SURVIVED the undo"))
    say("  >>> is the text gone? %s (undo ate the INSERT instead)"
        % ("YES" if text(buf) == "" else "NO"))

    say("\n--- P1.3 remove-tag under undo ---")
    win, sw, view, buf = mk()
    bold = buf.create_tag("bold", weight=Pango.Weight.BOLD)
    buf.insert(buf.get_end_iter(), "hello world")
    buf.apply_tag(bold, buf.get_iter_at_offset(0), buf.get_iter_at_offset(5))
    d0 = undo_depth(buf)
    buf.begin_user_action()
    buf.remove_tag(bold, buf.get_iter_at_offset(0), buf.get_iter_at_offset(5))
    buf.end_user_action()
    d1 = undo_depth(buf)
    say("after remove_tag: bold runs=%s depth=%d (was %d) -> entry pushed? %s"
        % (bold_span(buf, bold), d1, d0, "YES" if d1 > d0 else "NO"))
    if buf.get_can_undo():
        buf.undo()
        say("after undo():     text=%r bold runs=%s" % (text(buf), bold_span(buf, bold)))
        say("  >>> did the tag come back? %s" % ("YES" if bold_span(buf, bold) else "NO"))

    say("\n--- P1.4 MIXED: one user action that inserts AND tags ---")
    win, sw, view, buf = mk()
    bold = buf.create_tag("bold", weight=Pango.Weight.BOLD)
    buf.insert(buf.get_end_iter(), "abc ")
    d0 = undo_depth(buf)
    buf.begin_user_action()
    start_off = buf.get_char_count()
    buf.insert(buf.get_end_iter(), "BOLDTEXT")
    buf.apply_tag(bold, buf.get_iter_at_offset(start_off), buf.get_end_iter())
    buf.end_user_action()
    d1 = undo_depth(buf)
    say("after mixed action: text=%r bold runs=%s depth=%d (was %d)"
        % (text(buf), bold_span(buf, bold), d1, d0))
    buf.undo()
    say("after undo():       text=%r bold runs=%s" % (text(buf), bold_span(buf, bold)))
    say("  >>> text reverted? %s ; tag reverted with it? %s"
        % ("YES" if text(buf) == "abc " else "NO",
           "YES" if not bold_span(buf, bold) else "NO"))
    buf.redo()
    say("after redo():       text=%r bold runs=%s" % (text(buf), bold_span(buf, bold)))
    say("  >>> does REDO restore the tag on the re-inserted text? %s"
        % ("YES" if bold_span(buf, bold) else "NO — the text came back PLAIN"))

    say("\n--- P1.5 insert_with_tags (the tag rides the insert) ---")
    win, sw, view, buf = mk()
    bold = buf.create_tag("bold", weight=Pango.Weight.BOLD)
    buf.insert(buf.get_end_iter(), "abc ")
    d0 = undo_depth(buf)
    buf.insert_with_tags(buf.get_end_iter(), "XY", bold)
    d1 = undo_depth(buf)
    say("after insert_with_tags: text=%r bold=%s depth=%d (was %d)"
        % (text(buf), bold_span(buf, bold), d1, d0))
    buf.undo()
    say("after undo():           text=%r bold=%s" % (text(buf), bold_span(buf, bold)))
    buf.redo()
    say("after redo():           text=%r bold=%s" % (text(buf), bold_span(buf, bold)))
    say("  >>> redo restored the tag? %s" % ("YES" if bold_span(buf, bold) else "NO"))

    say("\n--- P1.6 does typed text INHERIT an adjacent tag? (GTK tag toggles) ---")
    win, sw, view, buf = mk()
    bold = buf.create_tag("bold", weight=Pango.Weight.BOLD)
    buf.insert(buf.get_end_iter(), "hello")
    buf.apply_tag(bold, buf.get_start_iter(), buf.get_end_iter())
    # insert INSIDE the bold run
    buf.insert(buf.get_iter_at_offset(2), "ZZ")
    say("insert inside bold run: text=%r bold=%s" % (text(buf), bold_span(buf, bold)))
    # insert at the END of the bold run
    buf.insert(buf.get_end_iter(), "TAIL")
    say("insert at end of run:   text=%r bold=%s" % (text(buf), bold_span(buf, bold)))
    say("  >>> interior insert inherits the tag; a trailing insert does NOT (right gravity of the end toggle)")

    # ---------------- 2. enable-undo FALSE ----------------
    say("\n=== P2 UNDO SUPPRESSION (R6's off switch on Linux) ===")
    win, sw, view, buf = mk()
    bold = buf.create_tag("bold", weight=Pango.Weight.BOLD)
    buf.set_enable_undo(False)
    say("enable-undo now =", buf.get_enable_undo())
    buf.begin_user_action()
    buf.insert(buf.get_end_iter(), "hello world")
    buf.end_user_action()
    say("after insert: text=%r can-undo=%s can-redo=%s"
        % (text(buf), buf.get_can_undo(), buf.get_can_redo()))
    buf.begin_user_action()
    buf.apply_tag(bold, buf.get_iter_at_offset(0), buf.get_iter_at_offset(5))
    buf.end_user_action()
    say("after apply_tag: bold=%s can-undo=%s" % (bold_span(buf, bold), buf.get_can_undo()))
    buf.undo()
    say("after undo() call: text=%r bold=%s  (a no-op? %s)"
        % (text(buf), bold_span(buf, bold),
           "YES" if text(buf) == "hello world" and bold_span(buf, bold) else "NO"))
    # The widget's own Ctrl+Z path: GtkTextView's "text.undo" action.
    win.present()
    ctx = GLib.MainContext.default()
    for _ in range(200):
        if not ctx.pending(): break
        ctx.iteration(False)
    ok = view.activate_action("text.undo", None)
    for _ in range(200):
        if not ctx.pending(): break
        ctx.iteration(False)
    say("view.activate_action('text.undo') returned %s; text=%r bold=%s"
        % (ok, text(buf), bold_span(buf, bold)))
    say("  >>> the widget's Ctrl+Z route is also inert: %s"
        % ("YES" if text(buf) == "hello world" else "NO"))
    en = view.get_action_group("text") if hasattr(view, "get_action_group") else None
    say("text.undo enabled state via action group:", en)

    say("\n--- P2.1 toggling enable-undo at runtime: is the BUFFER cleared? ---")
    win, sw, view, buf = mk()
    bold = buf.create_tag("bold", weight=Pango.Weight.BOLD)
    buf.insert(buf.get_end_iter(), "keep me")
    buf.apply_tag(bold, buf.get_iter_at_offset(0), buf.get_iter_at_offset(4))
    say("before toggle: text=%r bold=%s can-undo=%s" % (text(buf), bold_span(buf, bold), buf.get_can_undo()))
    buf.set_enable_undo(False)
    say("undo OFF:      text=%r bold=%s can-undo=%s" % (text(buf), bold_span(buf, bold), buf.get_can_undo()))
    buf.set_enable_undo(True)
    say("undo ON again: text=%r bold=%s can-undo=%s" % (text(buf), bold_span(buf, bold), buf.get_can_undo()))
    say("  >>> buffer content survives the toggle: %s ; history cleared by it: %s"
        % ("YES" if text(buf) == "keep me" else "NO",
           "YES" if not buf.get_can_undo() else "NO"))
    buf.insert(buf.get_end_iter(), "!")
    say("new edit after re-enable: text=%r can-undo=%s" % (text(buf), buf.get_can_undo()))
    buf.undo()
    say("undo() now:               text=%r" % text(buf))
    say("  >>> undo after re-enable only reaches edits made AFTER it: %s"
        % ("YES" if text(buf) == "keep me" else "NO"))

    say("\n--- P2.2 max-undo-levels ---")
    b = Gtk.TextBuffer()
    say("max-undo-levels default =", b.get_max_undo_levels())
    b.set_max_undo_levels(0)
    b.insert(b.get_end_iter(), "x")
    say("with max-undo-levels=0: can-undo=%s (0 means UNLIMITED in GTK, not off)" % b.get_can_undo())

    say("\n--- P2.3 irreversible action bracket (what kaya already uses for D7) ---")
    win, sw, view, buf = mk()
    buf.insert(buf.get_end_iter(), "a")
    say("can-undo before irreversible =", buf.get_can_undo())
    buf.begin_irreversible_action()
    buf.insert(buf.get_end_iter(), "b")
    buf.end_irreversible_action()
    say("can-undo after  irreversible =", buf.get_can_undo(), "text=%r" % text(buf))
    say("  >>> begin/end_irreversible_action CLEARS the whole history: %s"
        % ("YES" if not buf.get_can_undo() else "NO"))

main()
open("/out/p1_undo_scope.txt", "w", encoding="utf-8").write("\n".join(OUT) + "\n")
