"""The Linux arm: a desktop entry and the icon theme (packaging-plan P5).

An installed Linux app is two things the desktop reads before it runs:
`<id>.desktop` under `applications/` (the name, the icon NAME, the
command, and `DBusActivatable=true`, which is what lets a click on a
notification start the app again after it exited) and the declared
picture in the hicolor icon theme at the sizes GNOME asks for. Both are
generated into an XDG DATA ROOT — `applications/`,
`icons/hicolor/<n>x<n>/apps/`, `dbus-1/services/` — so staging and
installing are the same act at two paths, and `install()` is a copy
under ~/.local/share with no root.

THE NOTIFY LEG USES THIS (P5): tools/linux/install-desktop.py stages the
entry into the leg's private XDG_DATA_HOME, so the lane runs what an
installed app has rather than a hand-written entry beside it.

AND THE APP LINKS ARM (docs/app-links-plan.md §4): the entry claims the
scheme with `MimeType=x-scheme-handler/<scheme>;` and takes a URL with
`%u` on `Exec`, and `mimeapps_list()` is the one stanza `gio open`
consults to resolve it. `activation_findings()` is the refusal every
staging walks into — the three shapes measured 2026-09-09 that pass warm
and die cold, silently, or with no core built at all.
"""

import pathlib
import shutil

from . import mark
from .identity import load

# What the hicolor theme is asked for. 16 and 24 are the panel and the
# notification's own small slot; 512 is what GNOME Software and the
# activities overview scale from.
SIZES = (16, 24, 32, 48, 64, 128, 256, 512)


def desktop_entry(declared, exec_line):
    """`<id>.desktop`'s text. Icon is the app's ID, never a path: the
    theme lookup is by name, and a path pins one size.

    `%u` rides HERE and not through install-desktop.py's `exec_line()`:
    that function absolutises an argument the filesystem knows, and a
    field code is not a path. The service file's `Exec` must NOT gain
    one — a D-Bus service file takes no field codes at all.
    """
    return ("[Desktop Entry]\n"
            "Type=Application\n"
            f"Name={declared.name}\n"
            f"Exec={exec_line} %u\n"
            f"Icon={declared.id}\n"
            "Terminal=false\n"
            "DBusActivatable=true\n"
            "StartupNotify=true\n"
            f"MimeType=x-scheme-handler/{declared.scheme};\n"
            "Categories=Utility;\n")


def service_file(declared, exec_line):
    """The D-Bus activation half of `DBusActivatable=true`: without it a
    click that arrives with nothing of ours running has no way to start
    the app, and the portal answers the Register with a refusal."""
    return ("[D-BUS Service]\n"
            f"Name={declared.id}\n"
            f"Exec={exec_line}\n")


def mimeapps_list(declared):
    """`$XDG_CONFIG_HOME/mimeapps.list` — the whole of what `gio open`
    reads to resolve a scheme (measured 2026-09-09: the stock image
    carries neither `xdg-mime` nor `update-desktop-database`, and the
    stanza alone routes a cold and a warm open correctly). The two
    "Registered/Recommended" lists come from `mimeinfo.cache` and `gio
    open` does not consult them."""
    return ("[Default Applications]\n"
            f"x-scheme-handler/{declared.scheme}={declared.id}.desktop\n")


def activation_findings(data_home, app_id):
    """What a staged tree has to be before a `<scheme>://` URL can reach
    the app, each clause a shape measured 2026-09-08/09 that fails LATE
    and QUIETLY (the probes' notes; docs/app-links-plan.md §2.4).

    Read off the staged files rather than off the call that wrote them,
    so a hand-written entry beside the generator's is judged too.
    """
    data_home = pathlib.Path(data_home)
    entry = data_home / "applications" / f"{app_id}.desktop"
    service = data_home / "dbus-1/services" / f"{app_id}.service"
    bad = []
    if not entry.is_file():
        if service.is_file():
            bad.append(
                f"package linux: {service} was staged without "
                f"{entry} — nothing resolves the app id to a command, so "
                f"the app is startable over D-Bus and reachable from no "
                f"launcher and no `gio open` at all")
        return bad
    text = entry.read_text(encoding="utf-8")
    if "DBusActivatable=true" in text and not service.is_file():
        bad.append(
            f"package linux: {entry} declares DBusActivatable=true and "
            f"{service} was not staged. Every WARM assertion still "
            f"passes — a running instance owns the name — and `gio open` "
            f"with nothing running exits 2 saying `The name {app_id} was "
            f"not provided by any .service files`: a green lane and a "
            f"dead launcher")
    if "x-scheme-handler/" in text:
        exec_lines = [line for line in text.splitlines()
                      if line.startswith("Exec=")]
        if not any(" %u" in line or " %U" in line for line in exec_lines):
            bad.append(
                f"package linux: {entry} claims a scheme with MimeType= "
                f"and its Exec carries no %u, so on the spawn route (the "
                f"one taken whenever D-Bus activation is not) the URL is "
                f"dropped before the process starts and the app opens on "
                f"its default screen with no error anywhere: "
                f"{exec_lines or ['no Exec line at all']}")
    if service.is_file():
        service_text = service.read_text(encoding="utf-8")
        if "--gapplication-service" in service_text:
            bad.append(
                f"package linux: {service} passes "
                f"--gapplication-service, which suppresses `activate` "
                f"entirely (measured 2026-09-09: the event order becomes "
                f"startup, open). crates/kaya/src/gtk.rs builds its whole "
                f"core inside connect_activate, so a link would start a "
                f"process that builds no window at all")
    return bad


def stage(root, exec_line, out_dir, config_home=None):
    """Write the entry, the service file and the icon theme into
    `out_dir` (an XDG data root). Returns the paths written.

    `config_home` is an XDG CONFIG root and adds the scheme
    registration: `mimeapps.list` lives there and not under the data
    root, so the two paths are named separately rather than derived from
    each other. A caller that wants no scheme handler leaves it out.
    """
    declared = load(root)
    source = declared.icon_path.read_bytes()
    out = pathlib.Path(out_dir)
    written = []
    apps = out / "applications"
    apps.mkdir(parents=True, exist_ok=True)
    entry = apps / f"{declared.id}.desktop"
    entry.write_text(desktop_entry(declared, exec_line), encoding="utf-8")
    written.append(entry)
    services = out / "dbus-1/services"
    services.mkdir(parents=True, exist_ok=True)
    service = services / f"{declared.id}.service"
    service.write_text(service_file(declared, exec_line), encoding="utf-8")
    written.append(service)
    if config_home is not None:
        config = pathlib.Path(config_home)
        config.mkdir(parents=True, exist_ok=True)
        registration = config / "mimeapps.list"
        registration.write_text(mimeapps_list(declared), encoding="utf-8")
        written.append(registration)
    for px in SIZES:
        icon = out / f"icons/hicolor/{px}x{px}/apps/{declared.id}.png"
        mark.write(icon, mark.resample(source, px))
        written.append(icon)
    # THE PAIR, READ BACK OFF THE DISK: staging is the path nobody can
    # avoid, and each shape below passes every warm assertion.
    bad = activation_findings(out, declared.id)
    if bad:
        raise SystemExit("\n".join(bad))
    return written


def install(root, staging, data_home=None):
    """Copy a staged tree under ~/.local/share — a per-user install, no
    root. `staging` is what `stage()` wrote; the copy is what the desktop
    reads, so the two are never assembled twice."""
    if not (pathlib.Path(staging) / "applications").is_dir():
        raise SystemExit(
            f"package linux: {staging} carries no applications/ "
            f"directory, so there is no staged entry to install — run the "
            f"linux arm with --out {staging} first")
    home = pathlib.Path(data_home) if data_home is not None else (
        pathlib.Path.home() / ".local/share")
    home.mkdir(parents=True, exist_ok=True)
    shutil.copytree(staging, home, dirs_exist_ok=True)
    declared = load(root)
    return home / "applications" / f"{declared.id}.desktop"
