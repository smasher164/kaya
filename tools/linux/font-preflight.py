import os
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gdk, Gtk, Pango, PangoCairo  # noqa: I001


EXPECTED_SETTING = "IBM Plex Sans 11"
EXPECTED_FAMILY = "IBM Plex Sans"


def findings(backend, display_type, setting, family):
    found = []
    expected_display = {
        "x11": "GdkX11Display",
        "wayland": "GdkWaylandDisplay",
    }.get(backend, "<known GDK backend>")
    if display_type != expected_display:
        found.append(
            f'the display type is {display_type!r}, wanted {expected_display!r}'
        )
    if setting != EXPECTED_SETTING:
        found.append(
            f'gtk-font-name is {setting!r}, wanted {EXPECTED_SETTING!r}'
        )
    if family != EXPECTED_FAMILY:
        found.append(
            f'the requested face resolves to {family!r}, wanted {EXPECTED_FAMILY!r}'
        )
    return found


def observe():
    Gtk.init()
    display = Gdk.Display.get_default()
    display_type = "<no Gdk.Display>" if display is None else display.__gtype__.name
    settings = Gtk.Settings.get_default()
    if settings is None:
        return display_type, "<no Gtk.Settings>", "<unresolved>"
    setting = settings.get_property("gtk-font-name")
    description = Pango.FontDescription.from_string(setting)
    font_map = PangoCairo.FontMap.get_default()
    font = font_map.load_font(font_map.create_context(), description)
    if font is None:
        return display_type, setting, "<unresolved>"
    return display_type, setting, font.describe().get_family() or "<unnamed>"


def main():
    injected = findings("x11", "GdkWaylandDisplay", "Sans 10", "DejaVu Sans")
    wanted = [
        "the display type is 'GdkWaylandDisplay', wanted 'GdkX11Display'",
        "gtk-font-name is 'Sans 10', wanted 'IBM Plex Sans 11'",
        "the requested face resolves to 'DejaVu Sans', wanted 'IBM Plex Sans'",
    ]
    if injected != wanted:
        print(
            "font-preflight: SELF-TEST FAILED — three wrong readings were not "
            "refused exactly",
            file=sys.stderr,
        )
        print(f"font-preflight: wanted {wanted!r}", file=sys.stderr)
        print(f"font-preflight: got {injected!r}", file=sys.stderr)
        sys.exit(1)
    print("font-preflight: negative injected 3 wrong readings; all rejected")

    backend = os.environ.get("GDK_BACKEND", "<unset>")
    display_type, setting, family = observe()
    wrong = findings(backend, display_type, setting, family)
    for message in wrong:
        print(f"font-preflight: {backend}: {message}", file=sys.stderr)
    if wrong:
        sys.exit(1)
    print(
        f"font-preflight: {backend}: {display_type}; gtk-font-name {setting!r} "
        f"resolves to {family!r}"
    )


if __name__ == "__main__":
    main()
