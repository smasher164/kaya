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
    theme lookup is by name, and a path pins one size."""
    return ("[Desktop Entry]\n"
            "Type=Application\n"
            f"Name={declared.name}\n"
            f"Exec={exec_line}\n"
            f"Icon={declared.id}\n"
            "Terminal=false\n"
            "DBusActivatable=true\n"
            "StartupNotify=true\n"
            "Categories=Utility;\n")


def service_file(declared, exec_line):
    """The D-Bus activation half of `DBusActivatable=true`: without it a
    click that arrives with nothing of ours running has no way to start
    the app, and the portal answers the Register with a refusal."""
    return ("[D-BUS Service]\n"
            f"Name={declared.id}\n"
            f"Exec={exec_line}\n")


def stage(root, exec_line, out_dir):
    """Write the entry, the service file and the icon theme into
    `out_dir` (an XDG data root). Returns the paths written."""
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
    for px in SIZES:
        icon = out / f"icons/hicolor/{px}x{px}/apps/{declared.id}.png"
        mark.write(icon, mark.resample(source, px))
        written.append(icon)
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
