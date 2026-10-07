#!/usr/bin/env python3
"""The lane's session manager, as far as an idle inhibitor reaches it.

Runs INSIDE the linux container, on a media leg's own session bus
(tools/linux/media-leg.sh, tools/linux/capture-leg.py). The container has
no gnome-session, so this plays its inhibitor half with GNOME's own method
names, and IsInhibited is what `expect_display_awake` reads on x11 — the
record gnome-session keeps, not kaya's (docs/media-plan.md §2 rule 5).
Wayland's inhibitor is the compositor's and never reaches here.

`--portal-inhibit` also plays the portal's Inhibit interface, the only
route GtkApplication.inhibit() takes on x11 from GTK 4.20 (docs/traps.md,
"GTK 4.20 inhibits only through the portal"), forwarding into the same
record as xdg-desktop-portal-gtk forwards to gnome-session. GTK asks for
the portal only when the bus lists it ACTIVATABLE, so the caller first runs
`sessionmgr.py --write-service DIR` and starts the bus with DIR on its
XDG_DATA_DIRS; the service is already owned when anything asks for it.

Every call is logged to stderr with a `sessionmgr:` prefix.
"""

import pathlib
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: I001,E402

NAME = "org.gnome.SessionManager"
PATH = "/org/gnome/SessionManager"

XML = f"""
<node>
  <interface name="{NAME}">
    <method name="RegisterClient">
      <arg type="s" name="app_id" direction="in"/>
      <arg type="s" name="client_startup_id" direction="in"/>
      <arg type="o" name="client_id" direction="out"/>
    </method>
    <method name="Inhibit">
      <arg type="s" name="app_id" direction="in"/>
      <arg type="u" name="toplevel_xid" direction="in"/>
      <arg type="s" name="reason" direction="in"/>
      <arg type="u" name="flags" direction="in"/>
      <arg type="u" name="inhibit_cookie" direction="out"/>
    </method>
    <method name="Uninhibit">
      <arg type="u" name="inhibit_cookie" direction="in"/>
    </method>
    <method name="IsInhibited">
      <arg type="u" name="flags" direction="in"/>
      <arg type="b" name="is_inhibited" direction="out"/>
    </method>
  </interface>
</node>
"""

PORTAL_NAME = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
PORTAL_XML = """
<node>
  <interface name="org.freedesktop.portal.Inhibit">
    <method name="Inhibit">
      <arg type="s" name="window" direction="in"/>
      <arg type="u" name="flags" direction="in"/>
      <arg type="a{sv}" name="options" direction="in"/>
      <arg type="o" name="handle" direction="out"/>
    </method>
    <method name="CreateMonitor">
      <arg type="s" name="window" direction="in"/>
      <arg type="a{sv}" name="options" direction="in"/>
      <arg type="o" name="handle" direction="out"/>
    </method>
    <property name="version" type="u" access="read"/>
  </interface>
</node>
"""
REQUEST_XML = """
<node>
  <interface name="org.freedesktop.portal.Request">
    <method name="Close"/>
  </interface>
</node>
"""

inhibitors = {}
next_cookie = [1]
next_token = [0]
requests = {}


def say(line):
    print(f"sessionmgr: {line}", file=sys.stderr, flush=True)


def call(_conn, sender, _path, _iface, method, params, invocation):
    args = params.unpack()
    if method == "RegisterClient":
        say(f"RegisterClient {args!r} from {sender}")
        invocation.return_value(GLib.Variant("(o)", (f"{PATH}/Client1",)))
    elif method == "Inhibit":
        cookie = next_cookie[0]
        next_cookie[0] += 1
        inhibitors[cookie] = (sender, args[0], args[2], args[3])
        say(f"Inhibit app={args[0]!r} reason={args[2]!r} flags={args[3]} "
            f"from {sender} -> cookie {cookie}")
        invocation.return_value(GLib.Variant("(u)", (cookie,)))
    elif method == "Uninhibit":
        gone = inhibitors.pop(args[0], None)
        say(f"Uninhibit {args[0]} from {sender} "
            f"({'held' if gone else 'unknown cookie'})")
        invocation.return_value(None)
    elif method == "IsInhibited":
        held = any(flags & args[0] for (_, _, _, flags) in inhibitors.values())
        invocation.return_value(GLib.Variant("(b)", (held,)))


def portal_call(conn, sender, _path, _iface, method, params, invocation):
    args = params.unpack()
    next_token[0] += 1
    token = args[-1].get("handle_token", f"kaya{next_token[0]}")
    handle = f"{PORTAL_PATH}/request/{sender[1:].replace('.', '_')}/{token}"
    cookie = None
    if method == "Inhibit":
        cookie = next_cookie[0]
        next_cookie[0] += 1
        reason = args[2].get("reason", "")
        inhibitors[cookie] = (sender, "portal", reason, args[1])
        say(f"portal Inhibit window={args[0]!r} reason={reason!r} "
            f"flags={args[1]} from {sender} -> cookie {cookie} at {handle}")
    else:
        say(f"portal {method} from {sender} at {handle}")

    def close(_c, _s, _p, _i, _m, _params, inv):
        reg, held = requests.pop(handle, (None, None))
        if held is not None:
            inhibitors.pop(held, None)
        say(f"portal Request.Close {handle} "
            f"({'cookie ' + str(held) if held else 'no inhibitor'})")
        if reg is not None:
            conn.unregister_object(reg)
        inv.return_value(None)

    reg = conn.register_object(handle, Gio.DBusNodeInfo.new_for_xml(REQUEST_XML).interfaces[0],
                               close, None, None)
    requests[handle] = (reg, cookie)
    invocation.return_value(GLib.Variant("(o)", (handle,)))


def portal_property(*_):
    return GLib.Variant("u", 3)


def vanished(conn, _sender, _path, _iface, _signal, params):
    name, _old, new = params.unpack()
    if new:
        return
    for cookie in [c for c, v in inhibitors.items() if v[0] == name]:
        say(f"cookie {cookie}'s holder {name} left the bus")
        inhibitors.pop(cookie)


def write_service(root):
    services = pathlib.Path(root) / "dbus-1" / "services"
    services.mkdir(parents=True, exist_ok=True)
    (services / f"{PORTAL_NAME}.service").write_text(
        f"[D-BUS Service]\nName={PORTAL_NAME}\nExec=/bin/false\n", encoding="utf-8")
    return 0


def main():
    if sys.argv[1:2] == ["--write-service"]:
        return write_service(sys.argv[2])
    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    node = Gio.DBusNodeInfo.new_for_xml(XML)
    conn.register_object(PATH, node.interfaces[0], call, None, None)
    conn.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus",
                          "NameOwnerChanged", "/org/freedesktop/DBus", None,
                          Gio.DBusSignalFlags.NONE, vanished)
    loop = GLib.MainLoop()

    def acquired(*_):
        say(f"owns {NAME}")

    def lost(*_):
        say(f"could not own {NAME}")
        loop.quit()

    Gio.bus_own_name_on_connection(conn, NAME, Gio.BusNameOwnerFlags.NONE,
                                   acquired, lost)
    if "--portal-inhibit" in sys.argv[1:]:
        conn.register_object(PORTAL_PATH, Gio.DBusNodeInfo.new_for_xml(PORTAL_XML).interfaces[0],
                             portal_call, portal_property, None)

        def portal_acquired(*_):
            say(f"owns {PORTAL_NAME} (Inhibit only)")

        def portal_lost(*_):
            say(f"could not own {PORTAL_NAME}")
            loop.quit()

        Gio.bus_own_name_on_connection(conn, PORTAL_NAME, Gio.BusNameOwnerFlags.NONE,
                                       portal_acquired, portal_lost)
    loop.run()
    return 1


if __name__ == "__main__":
    sys.exit(main())
