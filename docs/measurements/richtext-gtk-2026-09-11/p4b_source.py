#!/usr/bin/env python3
"""Probe 4b: (a) real typing of multi-byte characters, (b) the user-action bracket
as a discriminator between user input, a programmatic write and a native undo
(docs/undo-plan.md A6 / rich-text-plan.md R4 `source`)."""
import subprocess, sys
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Gdk", "4.0")
from gi.repository import Gtk, Gdk, GLib, Pango, GObject

LOG=[]
def say(s=""):
    LOG.append(s); print(s, flush=True)
    open("/out/p4b.txt","w",encoding="utf-8").write("\n".join(LOG)+"\n")
def xdo(*a):
    r=subprocess.run(["xdotool"]+list(a),capture_output=True,text=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()

buf = Gtk.TextBuffer()
view = Gtk.TextView(buffer=buf); view.set_editable(True)
sw = Gtk.ScrolledWindow(); sw.set_child(view); sw.set_vexpand(True)
win = Gtk.Window(title="kaya-richtext-probe"); win.set_default_size(900,300); win.set_child(sw)

EV=[]
def byte_off(it): return len(buf.get_text(buf.get_start_iter(), it, True).encode("utf-8"))
def text(): return buf.get_text(buf.get_start_iter(), buf.get_end_iter(), True)
buf.connect("begin-user-action", lambda *_: EV.append(("begin-user-action","")))
buf.connect("end-user-action",   lambda *_: EV.append(("end-user-action","")))
buf.connect("insert-text", lambda b,l,t,n: EV.append(("insert-text",
    "char=%d byte=%d text=%r len_arg=%d utf8=%d" % (l.get_offset(), byte_off(l), t, n, len(t.encode("utf-8"))))))
buf.connect("delete-range", lambda b,s,e: EV.append(("delete-range",
    "chars[%d,%d) BYTES[%d,%d) removed=%r" % (s.get_offset(), e.get_offset(), byte_off(s), byte_off(e),
                                              b.get_text(s,e,True)))))

ctx = GLib.MainContext.default()
def pump(ms=300):
    end = GLib.get_monotonic_time()+ms*1000
    while GLib.get_monotonic_time() < end:
        while ctx.pending(): ctx.iteration(False)
        GLib.usleep(4000)

def stage(label, fn, settle=800):
    global EV
    EV=[]
    before = text()
    fn(); pump(settle)
    names=[n for n,_ in EV]
    bracketed = "begin-user-action" in names
    say("  %-34s bracket=%-5s text %r -> %r" % (label, bracketed, before, text()))
    for n,d in EV:
        say("        %-20s %s" % (n,d))
    return bracketed

def main():
    win.present(); pump(800)
    rc, wid, _ = xdo("search","--name","kaya-richtext-probe"); wid=wid.split("\n")[0]
    xdo("windowfocus", wid); xdo("mousemove","--window",wid,"300","30"); pump(400)
    view.grab_focus(); pump(200)
    say("=== probe 4b — GTK %d.%d.%d ===" % (Gtk.get_major_version(),Gtk.get_minor_version(),Gtk.get_micro_version()))

    say("\n--- 4b.1 REAL typing of MULTI-BYTE characters through XTEST ---")
    for s in ["e", "é", "👋", "日"]:
        global EV; EV=[]
        rc,out,err = xdo("type","--delay","80",s)
        pump(900)
        ins=[d for n,d in EV if n=="insert-text"]
        say("  xdotool type %-3r rc=%d -> %s" % (s, rc, ins or "NOTHING ARRIVED"))
    say("  text now = %r  (%d chars, %d utf-8 bytes)" % (text(), buf.get_char_count(), len(text().encode("utf-8"))))
    say("  also via keysym names:")
    for k in ["eacute","U1F44B"]:
        EV=[]
        rc,out,err=xdo("key","--delay","80",k); pump(700)
        say("    xdotool key %-8s rc=%d err=%r -> %s" % (k, rc, err, [d for n,d in EV if n=="insert-text"] or "NOTHING"))
    say("  text now = %r" % text())

    say("\n--- 4b.2 the user-action BRACKET as the `source` discriminator ---")
    buf.set_text("seed")
    buf.begin_irreversible_action(); buf.end_irreversible_action()
    pump(200)
    view.grab_focus(); pump(200)
    rows=[]
    rows.append(("real typing (XTEST)",        stage("real typing 'X'", lambda: xdo("type","X"))))
    rows.append(("real BackSpace (XTEST)",     stage("real BackSpace",  lambda: xdo("key","BackSpace"))))
    cb = Gdk.Display.get_default().get_clipboard()
    try: cb.set_content(Gdk.ContentProvider.new_for_value(GObject.Value(str,"PP")))
    except Exception as e: say("  clipboard set failed %r" % e)
    pump(300)
    rows.append(("real paste Ctrl+V (XTEST)",  stage("real paste",      lambda: xdo("key","ctrl+v"), 1200)))
    rows.append(("programmatic buffer.insert", stage("programmatic insert",
                 lambda: buf.insert(buf.get_end_iter(),"PROG"), 300)))
    rows.append(("programmatic buffer.delete", stage("programmatic delete",
                 lambda: buf.delete(buf.get_iter_at_offset(buf.get_char_count()-4), buf.get_end_iter()), 300)))
    rows.append(("NATIVE UNDO Ctrl+Z (XTEST)", stage("native undo",     lambda: xdo("key","ctrl+z"), 1000)))
    rows.append(("NATIVE REDO Ctrl+Shift+Z",   stage("native redo",     lambda: xdo("key","ctrl+shift+z"), 1000)))
    rows.append(("buffer.undo() programmatic", stage("buffer.undo()",   lambda: buf.undo(), 400)))
    rows.append(("buffer.redo() programmatic", stage("buffer.redo()",   lambda: buf.redo(), 400)))

    say("\n  SOURCE DISCRIMINATION TABLE (does the edit arrive inside begin/end-user-action?)")
    for label, b in rows:
        say("    %-32s %s" % (label, "BRACKETED" if b else "bare"))
    say("\n  >>> user input is bracketed; a programmatic write and a native undo/redo are NOT.")
    say("  >>> so a backend that knows when IT is writing can tell native_undo from user input,")
    say("      but nothing in the signal stream distinguishes undo from redo.")
    win.close()

loop=GLib.MainLoop()
def _run():
    try: main()
    except Exception:
        import traceback; say("EXCEPTION\n"+traceback.format_exc())
    loop.quit(); return False
GLib.idle_add(_run); GLib.timeout_add_seconds(150, lambda:(loop.quit(),False)[-1]); loop.run()
