#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# THE EXAMPLE MARK'S ONE WRITER (docs/packaging-plan.md P2, as ruled
# 2026-09-08). This repo's declared icon is a picture like any app's, so
# the packaging arms resample it and know nothing about what is in it;
# what they cannot do is produce it, and this is where it comes from.
# tools/check-app-identity.py holds the committed file byte-identical to
# mark.render_png() and refuses any other caller of that function under
# tools/ — so this script and that gate are the whole reach of the
# description.
#
#     tools/regen-mark.py [--check]
#
# Regenerating changes the file's BYTES, which is a tree-wide change: the
# gate compares them, the wire sends them and every packaged copy comes
# down from them.

from packaging import mark
from packaging.identity import load

declared = load(ROOT)
want = mark.render_png()
have = declared.icon_path.read_bytes() if declared.icon_path.is_file() else b""

if sys.argv[1:] == ["--check"]:
    if have == want:
        print(f"regen-mark: {declared.icon} is the description's own "
              f"{mark.SOURCE_PX}px picture ({len(want)} bytes)")
    else:
        print(f"regen-mark: {declared.icon} is {len(have)} bytes and the "
              f"description renders {len(want)} — run tools/regen-mark.py",
              file=sys.stderr)
        raise SystemExit(1)
elif sys.argv[1:]:
    raise SystemExit("usage: tools/regen-mark.py [--check]")
else:
    mark.write(declared.icon_path, want)
    print(f"regen-mark: wrote {declared.icon}, {mark.SOURCE_PX}x"
          f"{mark.SOURCE_PX}, {len(want)} bytes"
          f"{' (unchanged)' if have == want else ''}")
