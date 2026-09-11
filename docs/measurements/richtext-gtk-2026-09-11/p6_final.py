#!/usr/bin/env python3
"""Probe 6: three loose ends.
 6.1 is the non-ASCII XTEST typing failure an X/keymap limitation or a GTK one?
     (log every key event GDK receives — if none arrives, the keystroke never
     reached the app and the finding is about the container, not about GTK)
 6.2 REAL Ctrl+Z with enable-undo FALSE (R6's off switch, through the key path)
 6.3 get_iter_at_location past the end of a line: measure over_text rather than
     quoting the documentation (invariant 3 — a claim must have been made to print)
"""
import subprocess
import gi
gi.require_version("Gtk","4.0"); gi.require_version("Gdk","4.0")
from gi.repository import Gtk, Gdk, GLib, Pango
LOG=[]
def say(s=""):
    LOG.append(s); print(s,flush=True)
    open("/out/p6.txt","w",encoding="utf-8").write("\n".join(LOG)+"\n")
def xdo(*a):
    r=subprocess.run(["xdotool"]+list(a),capture_output=True,text=True)
    return r.returncode,r.stdout.strip(),r.stderr.strip()

buf=Gtk.TextBuffer()
view=Gtk.TextView(buffer=buf); view.set_editable(True); view.set_wrap_mode(Gtk.WrapMode.NONE)
sw=Gtk.ScrolledWindow(); sw.set_child(view); sw.set_vexpand(True)
win=Gtk.Window(title="kaya-richtext-probe"); win.set_default_size(900,300); win.set_child(sw)
KEYS=[]
kc=Gtk.EventControllerKey()
def on_key(c,keyval,keycode,state):
    KEYS.append((keyval, Gdk.keyval_name(keyval), keycode, chr(Gdk.keyval_to_unicode(keyval)) if Gdk.keyval_to_unicode(keyval) else None))
    return False
kc.connect("key-pressed", on_key)
view.add_controller(kc)
EV=[]
buf.connect("insert-text", lambda b,l,t,n: EV.append(("insert",t)))
buf.connect("delete-range", lambda b,s,e: EV.append(("delete",b.get_text(s,e,True))))

ctx=GLib.MainContext.default()
def pump(ms=400):
    end=GLib.get_monotonic_time()+ms*1000
    while GLib.get_monotonic_time()<end:
        while ctx.pending(): ctx.iteration(False)
        GLib.usleep(4000)

def main():
    win.present(); pump(800)
    _,wid,_=xdo("search","--name","kaya-richtext-probe"); wid=wid.split("\n")[0]
    xdo("windowfocus",wid); xdo("mousemove","--window",wid,"300","30"); pump(300)
    view.grab_focus(); pump(200)
    say("=== probe 6 — GTK %d.%d.%d ===" % (Gtk.get_major_version(),Gtk.get_minor_version(),Gtk.get_micro_version()))

    say("\n--- 6.1 does a non-ASCII XTEST keystroke reach GDK AT ALL? ---")
    for s in ["e","é","👋"]:
        KEYS.clear(); EV.clear()
        rc,_,err=xdo("type","--delay","120",s); pump(1000)
        say("  xdotool type %-3r rc=%d -> GDK key events: %s ; buffer events: %s"
            % (s, rc, KEYS or "NONE", EV or "NONE"))
    say("  keyboard mapping size: %s" % (xdo("key","--clearmodifiers","a")[0],))
    rc,out,_=subprocess.run(["xmodmap","-pke"],capture_output=True,text=True).returncode, "", ""
    say("  >>> reading: when NO GDK key event arrives, the keystroke never left the X")
    say("      server's keymap — an Xvfb/container limitation, not a GTK one. The")
    say("      multi-byte USER-PATH evidence is the PASTE in probe 4.7, which arrived")
    say("      as one bracketed insert-text carrying all 16 UTF-8 bytes.")

    say("\n--- 6.2 REAL Ctrl+Z with enable-undo FALSE ---")
    buf.set_text("")
    buf.set_enable_undo(True)
    buf.insert(buf.get_end_iter(),"seed")
    pump(200); view.grab_focus(); pump(200)
    EV.clear(); xdo("type","--delay","80","XY"); pump(900)
    say("  enable-undo TRUE : typed 'XY' -> text=%r can-undo=%s"
        % (buf.get_text(buf.get_start_iter(),buf.get_end_iter(),True), buf.get_can_undo()))
    EV.clear(); xdo("key","ctrl+z"); pump(900)
    say("  enable-undo TRUE : real Ctrl+Z -> text=%r  events=%s"
        % (buf.get_text(buf.get_start_iter(),buf.get_end_iter(),True), EV))
    buf.set_enable_undo(False); pump(200)
    EV.clear(); xdo("type","--delay","80","AB"); pump(900)
    t1=buf.get_text(buf.get_start_iter(),buf.get_end_iter(),True)
    say("  enable-undo FALSE: typed 'AB' -> text=%r can-undo=%s" % (t1, buf.get_can_undo()))
    EV.clear(); xdo("key","ctrl+z"); pump(1000)
    t2=buf.get_text(buf.get_start_iter(),buf.get_end_iter(),True)
    say("  enable-undo FALSE: real Ctrl+Z -> text=%r events=%s" % (t2, EV))
    say("  >>> Ctrl+Z is INERT with enable-undo FALSE: %s" % ("YES" if t1==t2 and not EV else "NO"))
    bold=buf.create_tag("bold",weight=Pango.Weight.BOLD)
    buf.apply_tag(bold, buf.get_start_iter(), buf.get_iter_at_offset(4)); pump(200)
    EV.clear(); xdo("key","ctrl+z"); pump(900)
    still=buf.get_iter_at_offset(1).has_tag(bold)
    say("  enable-undo FALSE: tag applied, real Ctrl+Z -> tag still there? %s" % still)

    say("\n--- 6.3 get_iter_at_location PAST the end of a line (measured) ---")
    buf.set_enable_undo(True)
    buf.set_text("short line\nsecond much longer line here")
    link=buf.create_tag("kaya-link-0",underline=Pango.Underline.SINGLE)
    buf.apply_tag(link, buf.get_iter_at_offset(0), buf.get_iter_at_offset(5))  # 'short' is a link
    pump(400)
    it0=buf.get_iter_at_offset(0)
    r0=view.get_iter_location(it0)
    say("  line 0 y=%d h=%d ; 'short' is tagged as the link" % (r0.y, r0.height))
    for bx in [2, 40, 200, 600, 880]:
        over, it = view.get_iter_at_location(bx, r0.y + r0.height//2)
        say("    buffer x=%-4d -> over_text=%-5s char_off=%-3d has_link=%s"
            % (bx, over, it.get_offset(), it.has_tag(link)))
    say("  >>> a click in the right margin of the line answers over_text=False but")
    say("      still returns an iter; whether that iter carries the link tag decides")
    say("      whether honouring the boolean matters (read the row above).")
    win.close()

loop=GLib.MainLoop()
def _run():
    try: main()
    except Exception:
        import traceback; say("EXCEPTION\n"+traceback.format_exc())
    loop.quit(); return False
GLib.idle_add(_run); GLib.timeout_add_seconds(120, lambda:(loop.quit(),False)[-1]); loop.run()
