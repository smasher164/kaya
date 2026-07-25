import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi
import sys

Atspi.init()

def walk(node, depth=0):
    if depth > 8:
        return
    try:
        role = node.get_role_name()
        name = node.get_name()
    except Exception as e:
        print("  " * depth + f"<err {e}>"); return
    # AT-SPI2 accessible-id: what GTK publishes for a widget's identity.
    try:
        aid = node.get_accessible_id()
    except Exception:
        aid = "<no get_accessible_id>"
    print("  " * depth + f"role={role!r} name={name!r} id={aid!r}")
    try:
        n = node.get_child_count()
    except Exception:
        n = 0
    for i in range(min(n, 40)):
        try:
            walk(node.get_child_at_index(i), depth + 1)
        except Exception:
            pass

desktop = Atspi.get_desktop(0)
want = sys.argv[1] if len(sys.argv) > 1 else None
for i in range(desktop.get_child_count()):
    app = desktop.get_child_at_index(i)
    try:
        nm = app.get_name()
    except Exception:
        continue
    if want and want not in (nm or ""):
        continue
    print(f"=== app {nm!r} ===")
    walk(app)
