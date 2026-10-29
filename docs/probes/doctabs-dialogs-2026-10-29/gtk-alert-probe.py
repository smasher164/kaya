import gi, subprocess
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, GLib
loop = GLib.MainLoop()
def report():
    out = subprocess.run(["xprop", "-root", "_NET_CLIENT_LIST"], capture_output=True, text=True).stdout
    tree = subprocess.run(["xwininfo", "-root", "-tree"], capture_output=True, text=True).stdout
    print(tree)
    for line in tree.splitlines():
        line = line.strip()
        if line.startswith("0x") and ('"' in line):
            wid = line.split()[0]
            p = subprocess.run(["xprop", "-id", wid, "WM_NAME", "WM_TRANSIENT_FOR", "_NET_WM_STATE", "_NET_WM_WINDOW_TYPE"], capture_output=True, text=True).stdout
            print("==", line); print(p)
    loop.quit()
    return False
def activate():
    w = Gtk.Window(title="parent window")
    w.set_default_size(640, 420); w.present()
    d = Gtk.AlertDialog(message="unsaved changes", detail="b has unsaved changes", buttons=["Discard", "Keep Editing"], modal=True)
    d.choose(w, None, lambda *x: None)
    GLib.timeout_add(1500, report)
activate()
loop.run()
