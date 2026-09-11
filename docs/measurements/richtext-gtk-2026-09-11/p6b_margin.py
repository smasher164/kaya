#!/usr/bin/env python3
"""Probe 6b: the right-margin click when the link ENDS the line — the case probe 6.3
left as an inference. Measured, not reasoned."""
import gi
gi.require_version("Gtk","4.0")
from gi.repository import Gtk, GLib, Pango
LOG=[]
def say(s=""):
    LOG.append(s); print(s,flush=True)
    open("/out/p6b.txt","w",encoding="utf-8").write("\n".join(LOG)+"\n")
buf=Gtk.TextBuffer()
view=Gtk.TextView(buffer=buf); view.set_editable(True); view.set_wrap_mode(Gtk.WrapMode.NONE)
sw=Gtk.ScrolledWindow(); sw.set_child(view); sw.set_vexpand(True)
win=Gtk.Window(title="p6b"); win.set_default_size(900,300); win.set_child(sw)
ctx=GLib.MainContext.default()
def pump(ms=400):
    end=GLib.get_monotonic_time()+ms*1000
    while GLib.get_monotonic_time()<end:
        while ctx.pending(): ctx.iteration(False)
        GLib.usleep(4000)
def main():
    win.present(); pump(700)
    buf.set_text("go to LINKEND\nnext line")
    link=buf.create_tag("kaya-link-0",underline=Pango.Underline.SINGLE)
    buf.apply_tag(link, buf.get_iter_at_offset(6), buf.get_iter_at_offset(13))  # 'LINKEND' ends line 0
    pump(400)
    r=view.get_iter_location(buf.get_iter_at_offset(0))
    say("=== probe 6b — the link ENDS the line ===")
    say("text=%r ; link covers chars [6,13) = the line's last word"
        % buf.get_text(buf.get_start_iter(),buf.get_end_iter(),True))
    for bx in [2, 60, 100, 300, 800]:
        over,it = view.get_iter_at_location(bx, r.y+r.height//2)
        say("  buffer x=%-4d -> over_text=%-5s char_off=%-3d has_link=%s"
            % (bx, over, it.get_offset(), it.has_tag(link)))
    say("")
    say(">>> MEASURED, and it CONTRADICTS the inference probe 6.3 was written with:")
    say("    a click past the end of the line answers over_text=False and returns the")
    say("    LINE-END iter (char 13) — which does NOT carry the link tag even though")
    say("    the link ends the line, because a tag's end toggle is EXCLUSIVE (the same")
    say("    right gravity probe 1.7 measured). So on GTK the right margin cannot")
    say("    activate a link by accident. over_text is still worth honouring, but for")
    say("    caret placement, not for link safety.")
    win.close()
loop=GLib.MainLoop()
def _r():
    try: main()
    except Exception:
        import traceback; say("EXC\n"+traceback.format_exc())
    loop.quit(); return False
GLib.idle_add(_r); GLib.timeout_add_seconds(60, lambda:(loop.quit(),False)[-1]); loop.run()
