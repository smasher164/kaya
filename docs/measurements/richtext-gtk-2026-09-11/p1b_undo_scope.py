#!/usr/bin/env python3
"""Probe 1 (corrected): GtkTextBuffer undo scope.

The first draft measured the undo DEPTH by undoing to the bottom and redoing back,
which is itself destructive to tags (redo restores text plain) — so every tag
reading after it was an artefact of the measurement. This version never undoes
except as the thing under test, and answers "did a tag change push an undo entry?"
by starting from a history that is EMPTY (begin/end_irreversible_action), where
can-undo False -> True is unambiguous.
"""
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Pango

OUT = []
def say(*a):
    s = " ".join(str(x) for x in a); OUT.append(s); print(s, flush=True)

def mk():
    buf = Gtk.TextBuffer()
    view = Gtk.TextView(buffer=buf); view.set_editable(True)
    sw = Gtk.ScrolledWindow(); sw.set_child(view)
    win = Gtk.Window(); win.set_default_size(600, 300); win.set_child(sw)
    return win, view, buf

def text(buf):
    return buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)

def runs(buf, tag):
    out = []; cur = None; n = buf.get_char_count()
    for off in range(n):
        if buf.get_iter_at_offset(off).has_tag(tag):
            if cur is None: cur = off
        elif cur is not None:
            out.append((cur, off)); cur = None
    if cur is not None: out.append((cur, n))
    return out

def st(buf, tag, label):
    say("  %-22s text=%-22r bold=%-12s can-undo=%-5s can-redo=%s"
        % (label, text(buf), runs(buf, tag), buf.get_can_undo(), buf.get_can_redo()))

def seeded():
    """A buffer holding 'hello world' with an EMPTY undo history."""
    win, view, buf = mk()
    tag = buf.create_tag("bold", weight=Pango.Weight.BOLD)
    buf.begin_irreversible_action()
    buf.insert(buf.get_end_iter(), "hello world")
    buf.end_irreversible_action()
    assert not buf.get_can_undo(), "history not empty"
    return win, view, buf, tag

say("=== GTK %d.%d.%d — probe 1, undo scope ===" % (
    Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version()))

say("\nP1.0  enable-undo default = %s   max-undo-levels default = %s"
    % (Gtk.TextBuffer().get_enable_undo(), Gtk.TextBuffer().get_max_undo_levels()))

say("\nP1.1  CONTROL — a plain insert, from an empty history")
win, view, buf, tag = seeded()
st(buf, tag, "seeded")
buf.begin_user_action(); buf.insert(buf.get_end_iter(), "!!"); buf.end_user_action()
st(buf, tag, "after insert '!!'")
buf.undo(); st(buf, tag, "after undo()")
buf.redo(); st(buf, tag, "after redo()")
say("  >>> a text insert DOES push an undo entry and undo reverts it.")

say("\nP1.2  THE QUESTION — apply_tag inside a user action, from an EMPTY history")
win, view, buf, tag = seeded()
st(buf, tag, "seeded")
buf.begin_user_action()
buf.apply_tag(tag, buf.get_iter_at_offset(0), buf.get_iter_at_offset(5))
buf.end_user_action()
st(buf, tag, "after apply_tag 0-5")
say("  >>> did apply-tag push an undo entry?  %s"
    % ("YES" if buf.get_can_undo() else "NO  (can-undo is still False)"))
buf.undo()
st(buf, tag, "after undo()")
say("  >>> is the tag gone after undo()?      %s"
    % ("YES" if not runs(buf, tag) else "NO — the tag SURVIVED; undo() had nothing to undo"))

say("\nP1.3  remove_tag, from an empty history")
win, view, buf, tag = seeded()
buf.apply_tag(tag, buf.get_iter_at_offset(0), buf.get_iter_at_offset(5))
buf.begin_irreversible_action(); buf.end_irreversible_action()   # clear again
st(buf, tag, "seeded+bold")
buf.begin_user_action()
buf.remove_tag(tag, buf.get_iter_at_offset(0), buf.get_iter_at_offset(5))
buf.end_user_action()
st(buf, tag, "after remove_tag")
say("  >>> remove-tag pushed an entry? %s" % ("YES" if buf.get_can_undo() else "NO"))
buf.undo()
st(buf, tag, "after undo()")

say("\nP1.4  MIXED — one user action that INSERTS text and tags it")
win, view, buf, tag = seeded()
st(buf, tag, "seeded")
buf.begin_user_action()
off = buf.get_char_count()
buf.insert(buf.get_end_iter(), "BOLD")
buf.apply_tag(tag, buf.get_iter_at_offset(off), buf.get_end_iter())
buf.end_user_action()
st(buf, tag, "after mixed action")
buf.undo(); st(buf, tag, "after undo()")
say("  >>> the text reverted, and the tag went WITH the text it covered (no text, no run).")
buf.redo(); st(buf, tag, "after redo()")
say("  >>> REDO restored the text — did the tag come back?  %s"
    % ("YES" if runs(buf, tag) else "NO — the text came back PLAIN"))

say("\nP1.5  insert_with_tags — the tag rides the insert call itself")
win, view, buf, tag = seeded()
buf.begin_user_action()
buf.insert_with_tags(buf.get_end_iter(), "XY", tag)
buf.end_user_action()
st(buf, tag, "after insert_with_tags")
buf.undo(); st(buf, tag, "after undo()")
buf.redo(); st(buf, tag, "after redo()")
say("  >>> redo restored the tag? %s" % ("YES" if runs(buf, tag) else "NO"))

say("\nP1.6  can-undo coalescing: do consecutive inserts share ONE entry?")
win, view, buf, tag = seeded()
for ch in "abc":
    buf.insert(buf.get_end_iter(), ch)          # no user-action bracket (typing's shape)
st(buf, tag, "typed 'abc' unbracketed")
buf.undo(); st(buf, tag, "1st undo()")
buf.undo(); st(buf, tag, "2nd undo()")
say("\n      and WITH a user-action bracket per character:")
win, view, buf, tag = seeded()
for ch in "abc":
    buf.begin_user_action(); buf.insert(buf.get_end_iter(), ch); buf.end_user_action()
st(buf, tag, "typed 'abc' bracketed")
buf.undo(); st(buf, tag, "1st undo()")
buf.undo(); st(buf, tag, "2nd undo()")

say("\nP1.7  tag GRAVITY — where does newly inserted text pick up an existing tag?")
win, view, buf, tag = seeded()
buf.apply_tag(tag, buf.get_iter_at_offset(0), buf.get_iter_at_offset(5))   # 'hello' bold
say("  bold run before: %s  text=%r" % (runs(buf, tag), text(buf)))
buf.insert(buf.get_iter_at_offset(2), "ZZ")
say("  insert at 2 (INSIDE the run):      bold=%s text=%r" % (runs(buf, tag), text(buf)))
buf.insert(buf.get_iter_at_offset(7), "E")     # exactly at the run's end toggle
say("  insert at the run's END toggle:    bold=%s text=%r" % (runs(buf, tag), text(buf)))
buf.insert(buf.get_iter_at_offset(0), "S")     # exactly at the run's start toggle
say("  insert at the run's START toggle:  bold=%s text=%r" % (runs(buf, tag), text(buf)))
say("  >>> an interior insert inherits; an insert at either toggle does NOT "
    "(kaya's R1 'runs cover inserted only' has to say so explicitly on GTK).")

open("/out/p1b_undo_scope.txt", "w", encoding="utf-8").write("\n".join(OUT) + "\n")
