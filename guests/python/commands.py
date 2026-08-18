"""The standard-commands scene, Python port: a chord on every leaf kind
(a checkable command, one option of a group, a plain command), the
punctuation keys those chords need, and the `settings` role — which
macOS shows in the application menu while the item stays addressable
where it was declared. Canonical semantics in guests/rust/commands.rs;
the byte-frozen contract in tools/scenes/commands.steps.
"""

import sys

import kaya

app = kaya.App()

settings_count = 0


def on_details(on):
    status.set("details on" if on else "details off")


def on_sorted(index):
    status.set("sorted date" if index == 1 else "sorted name")


def on_settings():
    # Fires twice on purpose: once by the chord, once by activating the
    # item at its DECLARED path — which on macOS lives in the
    # application menu by then.
    global settings_count
    settings_count += 1
    status.set(f"settings {settings_count}")


with app.window(title="commands"):
    status = kaya.signal("ready")
    details = kaya.signal(False)
    sort = kaya.signal(0.0)

    # An ordinary command sits beside Settings so the menu that declared
    # it is not left empty once macOS moves the settings item away.
    with app.menu("File"):
        kaya.item("Reload")
        kaya.item("Settings…", shortcut="primary+comma",
                  role=kaya.ROLE_SETTINGS, on_activate=on_settings)

    # Option order IS the index vocabulary: Name = 0, Date = 1.
    with app.menu("View"):
        kaya.toggle("Details", checked=details, shortcut="primary+backslash",
                    on_toggle=on_details)
        with kaya.radio_group("Sort", value=sort, on_select=on_sorted):
            kaya.option("Name", shortcut="primary+1")
            kaya.option("Date", shortcut="primary+2")

    with kaya.column():
        kaya.label(bind=status)  # label#0

sys.exit(app.run())
