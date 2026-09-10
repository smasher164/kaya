#!/usr/bin/env python3
"""Install the app's desktop entry and icon theme (packaging-plan P5).

    tools/linux/install-desktop.py [--config-home <dir>] <xdg-data-home> \
        <guest> [args...]

Runs INSIDE the linux container, beside notifyd.py and schedrec.py, so
it carries no dev-shell guard: the container is not the nix shell. What
it writes is the GENERATOR'S entry (tools/lib/packaging/linux.py), the
same one a per-user install puts under ~/.local/share, so the notify leg
runs what an installed app has rather than a hand-written file beside
it. It prints the declared app id, which is what the leg names its bus
assertions after.

THE EXEC LINE MUST BE ABSOLUTE. GLib refuses to build a GDesktopAppInfo
whose Exec program it cannot resolve, and the portal then answers a
Register with "App info not found for '<id>'" (measured 2026-09-08, when
this lane passed a relative wrapper path: every reminder in the tasks
scene went unposted because the capability read false, and the guest
said so in its own words rather than naming a cause).
"""

import os
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools/lib"))

from packaging import linux  # noqa: E402
from packaging.identity import load  # noqa: E402


def exec_line(argv):
    """The guest command with an absolute program AND absolute arguments.

    THE ARGUMENTS TOO, since S9 (docs/tasks-s9-plan.md R6): a relative one
    is resolved against the cwd of whoever STARTS the app, and a D-Bus
    activation is started by the bus daemon from `/`, not by the leg from
    /work. Measured 2026-09-08 — the tasks leg's act two died at
    `tools/linux/a11y-leg.sh: No such file or directory` while act one,
    started by the runner, had run the same line perfectly.
    """
    argv = list(argv)
    if not os.path.isabs(argv[0]):
        # NOT `shutil.which` ALONE: a name with a slash in it is checked
        # in place and returned AS GIVEN, so `tools/linux/a11y-leg.sh`
        # came back relative and the portal refused the app id all the
        # same.
        found = None if os.sep in argv[0] else shutil.which(argv[0])
        argv[0] = os.path.abspath(found or argv[0])
    if not os.path.isabs(argv[0]) or not os.path.exists(argv[0]):
        raise SystemExit(
            f"install-desktop: {argv[0]} is not an absolute path that "
            f"exists, so the desktop entry's Exec would name a program "
            f"the portal cannot resolve")
    # AN ARGUMENT IS A PATH WHEN THE FILESYSTEM SAYS SO: a scene name, a
    # flag or a guest's own word stays exactly as the leg spelled it.
    argv[1:] = [os.path.abspath(word)
                if not os.path.isabs(word) and os.path.exists(word) else word
                for word in argv[1:]]
    return " ".join(argv)


def main(argv):
    # `--config-home` adds the scheme registration mimeapps.list, which
    # lives under the CONFIG root and is what `gio open` resolves a
    # `<scheme>://` URL through (docs/app-links-plan.md §4). Only the
    # links leg asks for it; the notify and persist legs push doors that
    # need no scheme.
    config_home = None
    if argv[:1] == ["--config-home"]:
        if len(argv) < 2:
            raise SystemExit("install-desktop: --config-home takes a "
                             "directory")
        config_home, argv = argv[1], argv[2:]
    if len(argv) < 2:
        raise SystemExit(
            "usage: install-desktop.py [--config-home <dir>] "
            "<xdg-data-home> <guest> [args...]")
    data_home = pathlib.Path(argv[0])
    written = linux.stage(ROOT, exec_line(argv[1:]), data_home, config_home)
    print(f"install-desktop: {len(written)} files under {data_home}",
          file=sys.stderr)
    print(load(ROOT).id)


main(sys.argv[1:])
