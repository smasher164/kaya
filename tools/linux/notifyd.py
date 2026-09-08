#!/usr/bin/env python3
"""The lane's notification daemon and recorder (docs/tasks-s3-plan.md N5).

Runs INSIDE the linux container, on the leg's own session bus. A Linux
desktop notification is one D-Bus call to whoever owns
`org.freedesktop.Notifications`; the container has no desktop, so this
plays the daemon (mako, dunst, Plasma — they all speak this one
protocol) and, beside it, GNOME Shell's `org.gtk.Notifications`, so both
halves of the ruled floor's regime 1 are real here.

THE PLATFORM'S OWN LIST IS WHAT `expect_notification` READS (S2b R4): the
harness never asks kaya what it posted. There is no standard query in the
freedesktop protocol — a daemon draws and forgets — so the recorder's own
`dev.kaya.NotificationRecorder` interface is the read-back:

    List()          -> a(sssss)  route, id, app_name, summary, body
    Invoke(key, s)               the click, on the REAL route
    Reset()                      forget everything (between legs)

`Invoke` is the user's finger: on an fdo entry it emits `ActionInvoked`
on the bus (what a click on a mako box does), and on a gtk entry it calls
`org.freedesktop.Application.ActivateAction` on the app's own bus name,
which is what GNOME Shell does and what D-Bus-activates an app that has
exited.

Every call is logged to stderr with a `notifyd:` prefix; the leg log is
where the transport is read after a red leg.
"""

import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: I001,E402

FDO_NAME = "org.freedesktop.Notifications"
FDO_PATH = "/org/freedesktop/Notifications"
GTK_NAME = "org.gtk.Notifications"
GTK_PATH = "/org/gtk/Notifications"
REC_NAME = "dev.kaya.NotificationRecorder"
REC_PATH = "/dev/kaya/NotificationRecorder"

XML = f"""
<node>
  <interface name="{FDO_NAME}">
    <method name="Notify">
      <arg type="s" name="app_name" direction="in"/>
      <arg type="u" name="replaces_id" direction="in"/>
      <arg type="s" name="app_icon" direction="in"/>
      <arg type="s" name="summary" direction="in"/>
      <arg type="s" name="body" direction="in"/>
      <arg type="as" name="actions" direction="in"/>
      <arg type="a{{sv}}" name="hints" direction="in"/>
      <arg type="i" name="expire_timeout" direction="in"/>
      <arg type="u" name="id" direction="out"/>
    </method>
    <method name="CloseNotification">
      <arg type="u" name="id" direction="in"/>
    </method>
    <method name="GetCapabilities">
      <arg type="as" name="capabilities" direction="out"/>
    </method>
    <method name="GetServerInformation">
      <arg type="s" name="name" direction="out"/>
      <arg type="s" name="vendor" direction="out"/>
      <arg type="s" name="version" direction="out"/>
      <arg type="s" name="spec_version" direction="out"/>
    </method>
    <signal name="NotificationClosed">
      <arg type="u" name="id"/>
      <arg type="u" name="reason"/>
    </signal>
    <signal name="ActionInvoked">
      <arg type="u" name="id"/>
      <arg type="s" name="action_key"/>
    </signal>
  </interface>
  <interface name="{GTK_NAME}">
    <method name="AddNotification">
      <arg type="s" name="app_id" direction="in"/>
      <arg type="s" name="id" direction="in"/>
      <arg type="a{{sv}}" name="notification" direction="in"/>
    </method>
    <method name="RemoveNotification">
      <arg type="s" name="app_id" direction="in"/>
      <arg type="s" name="id" direction="in"/>
    </method>
  </interface>
  <interface name="{REC_NAME}">
    <method name="List">
      <arg type="a(sssss)" name="held" direction="out"/>
    </method>
    <method name="Invoke">
      <arg type="s" name="key" direction="in"/>
      <arg type="s" name="action" direction="in"/>
      <arg type="s" name="what" direction="out"/>
    </method>
    <method name="Reset">
      <arg type="u" name="dropped" direction="out"/>
    </method>
  </interface>
</node>
"""


def log(message):
    print(f"notifyd: {message}", file=sys.stderr, flush=True)


class Held:
    """One notification the daemon is holding, either transport."""

    def __init__(self, route, ident, app_name, summary, body, actions,
                 app_id="", default_action="", default_target=None):
        self.route = route
        self.ident = ident
        self.app_name = app_name
        self.summary = summary
        self.body = body
        self.actions = actions
        self.app_id = app_id
        self.default_action = default_action
        self.default_target = default_target

    def row(self):
        return (self.route, self.ident, self.app_name, self.summary,
                self.body)


class Daemon:
    def __init__(self, connection):
        self.connection = connection
        self.held = []
        self.next_fdo_id = 1

    # ---------------------------------------------------------- the fdo half

    def notify(self, app_name, replaces_id, summary, body, actions, hints):
        if replaces_id:
            self.drop(str(replaces_id), reason=4)
            ident = replaces_id
        else:
            ident = self.next_fdo_id
            self.next_fdo_id += 1
        # THE ATTRIBUTION FIELD, filled the way a daemon fills it: the
        # portal's backend posts with an empty app_name and names the app in
        # the `desktop-entry` hint instead, and that is the only trace of who
        # posted that survives the hop (docs/tasks-s3-plan.md §0).
        entry = hints.get("desktop-entry", "")
        self.held.append(Held("fdo", str(ident), app_name or entry, summary,
                              body, actions))
        # THE HINTS ARE PRINTED WITH THEIR VALUES: `desktop-entry` is how a
        # daemon attributes a notification to an app, and on the portal
        # route it is the only trace of who posted (docs/tasks-s3-plan.md
        # §0) — the measurement belongs in the leg log, not in a session.
        shown = ", ".join(f"{k}={v}" for k, v in sorted(hints.items()))
        log(f"Notify app_name={app_name!r} id={ident} summary={summary!r} "
            f"body={body!r} actions={actions} hints={{{shown}}}")
        return ident

    def emit(self, signal, variant):
        self.connection.emit_signal(None, FDO_PATH, FDO_NAME, signal, variant)

    # ---------------------------------------------------------- the gtk half

    def add_gtk(self, app_id, ident, notification):
        """`notification` arrives as the RAW a{sv}: the default action's
        target is passed on to ActivateAction as the variant the app sent,
        and unpacking it here would lose the type the action expects."""
        self.drop_gtk(app_id, ident, notify_closed=False)

        def text(key):
            value = notification.lookup_value(key, None)
            return value.get_string() if value is not None else ""

        title = text("title")
        body = text("body")
        action = text("default-action")
        target = notification.lookup_value("default-action-target", None)
        self.held.append(Held("gtk", ident, app_id, title, body, [],
                              app_id=app_id, default_action=action,
                              default_target=target))
        log(f"AddNotification app_id={app_id!r} id={ident!r} title={title!r} "
            f"body={body!r} default-action={action!r} "
            f"default-action-target="
            f"{target.print_(True) if target is not None else 'none'}")

    def drop_gtk(self, app_id, ident, notify_closed=True):
        for entry in list(self.held):
            if entry.route == "gtk" and entry.app_id == app_id \
                    and entry.ident == ident:
                self.held.remove(entry)
                if notify_closed:
                    log(f"RemoveNotification app_id={app_id!r} id={ident!r}")

    # ------------------------------------------------------------ both halves

    def drop(self, ident, reason=3):
        """Close by id, the way a daemon does — the fdo half signals."""
        for entry in list(self.held):
            if entry.ident == ident:
                self.held.remove(entry)
                log(f"closed {entry.route}:{ident} ({entry.summary!r}), "
                    f"reason {reason}")
                if entry.route == "fdo":
                    self.emit("NotificationClosed",
                              GLib.Variant("(uu)", (int(ident), reason)))
                return True
        return False

    def find(self, key):
        """The entry an id OR a summary names, most recent first. The
        summary is a join key because the freedesktop protocol carries no
        client id: a notification posted THROUGH the portal reaches this
        daemon with the portal's own id, and only its text survives."""
        for entry in reversed(self.held):
            if entry.ident == key or entry.summary == key:
                return entry
        return None

    def invoke(self, key, action):
        """The click, on the transport the notification actually took."""
        entry = self.find(key)
        if entry is None:
            held = ", ".join(f"{e.route}:{e.ident} {e.summary!r}"
                             for e in self.held) or "nothing"
            return (f"no notification matches {key!r}; the daemon holds "
                    f"{held}")
        if entry.route == "fdo":
            name = action or (entry.actions[0] if entry.actions else "default")
            self.emit("ActionInvoked",
                      GLib.Variant("(us)", (int(entry.ident), name)))
            self.drop(entry.ident, reason=2)
            log(f"Invoke fdo id={entry.ident} action={name!r} — ActionInvoked "
                f"emitted, the notification closed")
            return f"fdo:{entry.ident} ActionInvoked {name}"
        return self.invoke_gtk(entry, action)

    def invoke_gtk(self, entry, action):
        """GNOME Shell's own answer to a click: ActivateAction on the
        app's bus name, which D-Bus activation launches when the app has
        exited (the two files in the leg's XDG dirs)."""
        name = action or entry.default_action or "app.activate"
        name = name.removeprefix("app.")
        path = "/" + entry.app_id.replace(".", "/").replace("-", "_")
        args = []
        if entry.default_target is not None:
            args.append(entry.default_target)
        # FIRE AND FORGET, as a shell does: kaya's activation handler
        # withdraws the notification through this same daemon, and a daemon
        # blocked on the app's reply while the app is blocked on ours is a
        # deadlock until both timeouts expire.
        def answered(connection, result, _data):
            try:
                connection.call_finish(result)
            except GLib.Error as error:
                log(f"Invoke gtk id={entry.ident} ActivateAction {name!r} on "
                    f"{entry.app_id} FAILED: {error.message}")

        self.connection.call(
            entry.app_id, path, "org.freedesktop.Application",
            "ActivateAction",
            GLib.Variant("(sava{sv})", (name, args, {})),
            None, Gio.DBusCallFlags.NONE, 10000, None, answered, None)
        self.held.remove(entry)
        log(f"Invoke gtk id={entry.ident} action={name!r} target="
            f"{entry.default_target} — ActivateAction called on "
            f"{entry.app_id}{path}, the notification withdrawn")
        return f"gtk:{entry.ident} ActivateAction {name}"


# PyGObject's Gio override wraps the closure and drops the `user_data`
# GIO passes, so the handler takes SEVEN arguments and reads the daemon
# from here — with the eighth it raises TypeError inside the closure and
# the caller sees a D-Bus timeout with the traceback only in this log.
DAEMON = None


def method_call(connection, sender, path, interface, method, params,
                invocation):
    daemon = DAEMON
    if interface == FDO_NAME:
        if method == "Notify":
            app_name, replaces, _icon, summary, body, actions, hints, _t = \
                params.unpack()
            ident = daemon.notify(app_name, replaces, summary, body, actions,
                                  hints)
            invocation.return_value(GLib.Variant("(u)", (ident,)))
            return
        if method == "CloseNotification":
            (ident,) = params.unpack()
            daemon.drop(str(ident))
            invocation.return_value(None)
            return
        if method == "GetCapabilities":
            invocation.return_value(GLib.Variant(
                "(as)", (["actions", "body", "body-markup", "persistence",
                          "icon-static"],)))
            return
        if method == "GetServerInformation":
            invocation.return_value(GLib.Variant(
                "(ssss)", ("kaya-notifyd", "kaya", "1.0", "1.2")))
            return
    elif interface == GTK_NAME:
        if method == "AddNotification":
            app_id = params.get_child_value(0).get_string()
            ident = params.get_child_value(1).get_string()
            daemon.add_gtk(app_id, ident, params.get_child_value(2))
            invocation.return_value(None)
            return
        if method == "RemoveNotification":
            app_id, ident = params.unpack()
            daemon.drop_gtk(app_id, ident)
            invocation.return_value(None)
            return
    elif interface == REC_NAME:
        if method == "List":
            invocation.return_value(GLib.Variant(
                "(a(sssss))", ([e.row() for e in daemon.held],)))
            return
        if method == "Invoke":
            key, action = params.unpack()
            invocation.return_value(
                GLib.Variant("(s)", (daemon.invoke(key, action),)))
            return
        if method == "Reset":
            dropped = len(daemon.held)
            for entry in list(daemon.held):
                daemon.drop(entry.ident, reason=3)
            daemon.held = []
            log(f"Reset — {dropped} dropped")
            invocation.return_value(GLib.Variant("(u)", (dropped,)))
            return
    invocation.return_error_literal(
        Gio.dbus_error_quark(), Gio.DBusError.UNKNOWN_METHOD,
        f"kaya notifyd has no {interface}.{method}")


def main():
    # WHICH HALVES TO PLAY is the leg's choice, because the REGIME is what
    # a notify leg measures: `fdo` alone is the daemon behind the portal,
    # `gtk` alone is GNOME's own interface, and a leg that wants the
    # refusal (regime 3) runs neither (docs/tasks-s3-plan.md §0).
    wanted = os.environ.get("KAYA_NOTIFYD_NAMES", "fdo,gtk").split(",")
    wanted = [w.strip() for w in wanted if w.strip()]
    global DAEMON
    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    node = Gio.DBusNodeInfo.new_for_xml(XML)
    daemon = Daemon(connection)
    DAEMON = daemon
    exports = [(REC_PATH, REC_NAME)]
    if "fdo" in wanted:
        exports.append((FDO_PATH, FDO_NAME))
    if "gtk" in wanted:
        exports.append((GTK_PATH, GTK_NAME))
    for path, interface in exports:
        connection.register_object(path, node.lookup_interface(interface),
                                   method_call, None, None)
    loop = GLib.MainLoop()
    pending = {REC_NAME}
    if "fdo" in wanted:
        pending.add(FDO_NAME)
    if "gtk" in wanted:
        pending.add(GTK_NAME)

    def acquired(_connection, name):
        pending.discard(name)
        log(f"owns {name}")
        if not pending:
            # THE READY LINE THE LEG WAITS FOR: a guest that posts before
            # the daemon owns its name posts into nothing, and the leg
            # would read an empty list with no cause on the record.
            print("notifyd: ready", flush=True)

    def lost(_connection, name):
        log(f"LOST {name} — another owner took it; this leg's reads are "
            f"someone else's notifications")
        loop.quit()

    for name in sorted(pending):
        Gio.bus_own_name_on_connection(
            connection, name, Gio.BusNameOwnerFlags.NONE, acquired, lost)
    loop.run()


main()
