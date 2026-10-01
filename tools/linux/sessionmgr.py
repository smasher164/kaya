#!/usr/bin/env python3
"""The lane's session manager, as far as an idle inhibitor reaches it.

Runs INSIDE the linux container, on a media leg's own session bus
(tools/linux/media-leg.sh). On x11, GtkApplication.inhibit() goes to
`org.gnome.SessionManager` when that name is on the bus at startup
(gtkapplication-dbus.c); the container has no gnome-session, so this plays
its inhibitor half with GNOME's own method names, and IsInhibited is what
`expect_display_awake` reads — the record gnome-session keeps, not kaya's
(docs/media-plan.md §2 rule 5). Wayland's inhibitor is the compositor's and
never reaches here.

Every call is logged to stderr with a `sessionmgr:` prefix.
"""

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

inhibitors = {}
next_cookie = [1]


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


def vanished(conn, _sender, _path, _iface, _signal, params):
    name, _old, new = params.unpack()
    if new:
        return
    for cookie in [c for c, v in inhibitors.items() if v[0] == name]:
        say(f"cookie {cookie}'s holder {name} left the bus")
        inhibitors.pop(cookie)


def main():
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
    loop.run()
    return 1


if __name__ == "__main__":
    sys.exit(main())
