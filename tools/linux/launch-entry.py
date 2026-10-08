#!/usr/bin/env python3
"""The plain door: a desktop entry launched the way a launcher launches it.

    tools/linux/launch-entry.py <entry.desktop> [ceiling-seconds]

Runs INSIDE the linux container (persist-leg.py's rule). GLib's own
GDesktopAppInfo, through launch_uris_async, held until GLib answers. NOT
`gio launch`, which loses the Activate call under load (docs/traps.md, the
plain door's lost Activate).
"""

import sys

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GioUnix", "2.0")
from gi.repository import Gio, GioUnix, GLib  # noqa: E402


def main(argv):
    if not argv:
        print("launch-entry: usage: launch-entry.py <entry.desktop> "
              "[ceiling-seconds]", file=sys.stderr)
        return 2
    ceiling = float(argv[1]) if len(argv) > 1 else 30.0
    info = GioUnix.DesktopAppInfo.new_from_filename(argv[0])
    if info is None:
        print(f"launch-entry: GLib will not load {argv[0]}", file=sys.stderr)
        return 1
    loop = GLib.MainLoop()
    answer = {}

    def done(source, result):
        try:
            answer["ok"] = source.launch_uris_finish(result)
        except GLib.Error as error:
            answer["error"] = f"{error.domain} {error.code}: {error.message}"
        loop.quit()

    def expired():
        answer["error"] = f"GLib gave no answer within {ceiling:.0f}s"
        loop.quit()
        return False

    info.launch_uris_async([], Gio.AppLaunchContext(), None, done)
    GLib.timeout_add(int(ceiling * 1000), expired)
    loop.run()
    if "error" in answer:
        print(f"launch-entry: {argv[0]} was not launched: {answer['error']}",
              file=sys.stderr)
        return 1
    print(f"launch-entry: GLib answered the launch of {info.get_id()}: "
          f"{answer['ok']}")
    return 0


sys.exit(main(sys.argv[1:]))
